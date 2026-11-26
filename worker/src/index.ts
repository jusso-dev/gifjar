import { env } from "cloudflare:workers";

/**
 * Stash API — storage backend for the Stash iOS app.
 *
 * R2 layout:
 *   media/<id>        original bytes (GIF, PNG, JPEG, HEIC, WebP…)
 *   meta/<id>.json    item metadata (title, notes, phrases, AI tags…) or a tombstone
 *
 * Every route requires `Authorization: Bearer <API_TOKEN>`.
 *
 *   GET    /v1/items                 list all metadata (incl. tombstones) — ?since=<ms> to filter
 *   PUT    /v1/items/:id             upsert metadata (last writer wins on updatedAt)
 *   DELETE /v1/items/:id             delete media, leave a tombstone so other devices sync the delete
 *   PUT    /v1/items/:id/media       upload original bytes (Content-Type required)
 *   GET    /v1/items/:id/media       download original bytes (ETag / If-None-Match aware)
 *   GET    /v1/health                auth check for the app's "Test Connection"
 */

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_MEDIA_BYTES = 50 * 1024 * 1024;
const MAX_META_BYTES = 256 * 1024;
const ALLOWED_TYPES = new Set([
	"image/gif",
	"image/png",
	"image/jpeg",
	"image/heic",
	"image/heif",
	"image/webp",
	"image/apng",
]);

interface ItemMeta {
	id: string;
	updatedAt: number; // ms since epoch
	deleted?: boolean;
	[key: string]: unknown;
}

const json = (body: unknown, status = 200) =>
	new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json; charset=utf-8" },
	});

const error = (status: number, message: string) => json({ error: message }, status);

async function authorized(request: Request): Promise<boolean> {
	const header = request.headers.get("authorization") ?? "";
	const token = header.startsWith("Bearer ") ? header.slice(7) : "";
	if (!token || !env.API_TOKEN) return false;
	// Constant-time comparison via digests (equal length, no early exit).
	const enc = new TextEncoder();
	const [a, b] = await Promise.all([
		crypto.subtle.digest("SHA-256", enc.encode(token)),
		crypto.subtle.digest("SHA-256", enc.encode(env.API_TOKEN)),
	]);
	return crypto.subtle.timingSafeEqual(a, b);
}

async function readMeta(id: string): Promise<ItemMeta | null> {
	const obj = await env.STASH.get(`meta/${id}.json`);
	return obj ? ((await obj.json()) as ItemMeta) : null;
}

async function listItems(since: number): Promise<ItemMeta[]> {
	const keys: string[] = [];
	let cursor: string | undefined;
	do {
		const page = await env.STASH.list({ prefix: "meta/", cursor, include: ["customMetadata"] });
		for (const obj of page.objects) {
			const updatedAt = Number(obj.customMetadata?.updatedAt ?? 0);
			if (updatedAt > since) keys.push(obj.key);
		}
		cursor = page.truncated ? page.cursor : undefined;
	} while (cursor);

	// Fetch in bounded batches to stay well inside subrequest limits.
	const items: ItemMeta[] = [];
	for (let i = 0; i < keys.length; i += 50) {
		const batch = await Promise.all(
			keys.slice(i, i + 50).map(async (key) => {
				const obj = await env.STASH.get(key);
				return obj ? ((await obj.json()) as ItemMeta) : null;
			}),
		);
		for (const item of batch) if (item) items.push(item);
	}
	return items;
}

async function putMeta(id: string, request: Request): Promise<Response> {
	const text = await request.text();
	if (text.length > MAX_META_BYTES) return error(413, "Metadata too large");

	let incoming: ItemMeta;
	try {
		incoming = JSON.parse(text);
	} catch {
		return error(400, "Body must be JSON");
	}
	if (incoming?.id !== id || typeof incoming.updatedAt !== "number") {
		return error(400, "Body must include matching id and numeric updatedAt");
	}

	const existing = await readMeta(id);
	if (existing && existing.updatedAt > incoming.updatedAt) {
		// Server copy is newer: tell the client to adopt it.
		return json(existing, 409);
	}
	if (existing?.deleted && !incoming.deleted) {
		return json(existing, 409);
	}

	await env.STASH.put(`meta/${id}.json`, JSON.stringify(incoming), {
		httpMetadata: { contentType: "application/json" },
		customMetadata: { updatedAt: String(incoming.updatedAt) },
	});
	return json(incoming);
}

async function deleteItem(id: string): Promise<Response> {
	const tombstone: ItemMeta = { id, updatedAt: Date.now(), deleted: true };
	await env.STASH.delete(`media/${id}`);
	await env.STASH.put(`meta/${id}.json`, JSON.stringify(tombstone), {
		httpMetadata: { contentType: "application/json" },
		customMetadata: { updatedAt: String(tombstone.updatedAt) },
	});
	return json(tombstone);
}

async function putMedia(id: string, request: Request): Promise<Response> {
	const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
	if (!ALLOWED_TYPES.has(type)) return error(415, `Unsupported media type: ${type || "none"}`);

	const length = Number(request.headers.get("content-length") ?? "0");
	if (length > MAX_MEDIA_BYTES) return error(413, "Media too large");
	if (!request.body) return error(400, "Missing body");

	const existingMeta = await readMeta(id);
	if (existingMeta?.deleted) return error(410, "Item was deleted");

	const obj = await env.STASH.put(`media/${id}`, request.body, {
		httpMetadata: { contentType: type, cacheControl: "private, max-age=31536000, immutable" },
	});
	return json({ id, size: obj?.size ?? 0, etag: obj?.httpEtag });
}

async function getMedia(id: string, request: Request): Promise<Response> {
	const obj = await env.STASH.get(`media/${id}`, { onlyIf: request.headers });
	if (!obj) return error(404, "Not found");

	const headers = new Headers();
	obj.writeHttpMetadata(headers);
	headers.set("etag", obj.httpEtag);
	if (!("body" in obj)) return new Response(null, { status: 304, headers });
	return new Response(obj.body, { headers });
}

export default {
	async fetch(request) {
		const url = new URL(request.url);
		const parts = url.pathname.split("/").filter(Boolean); // ["v1", "items", id?, "media"?]

		if (parts[0] !== "v1") return error(404, "Not found");
		if (!(await authorized(request))) return error(401, "Unauthorized");

		if (parts[1] === "health" && parts.length === 2 && request.method === "GET") {
			return json({ ok: true });
		}
		if (parts[1] !== "items") return error(404, "Not found");

		if (parts.length === 2) {
			if (request.method !== "GET") return error(405, "Method not allowed");
			const since = Number(url.searchParams.get("since") ?? "0") || 0;
			return json({ items: await listItems(since), serverTime: Date.now() });
		}

		const id = parts[2].toLowerCase();
		if (!ID.test(id)) return error(400, "Invalid id");

		if (parts.length === 3) {
			switch (request.method) {
				case "GET": {
					const meta = await readMeta(id);
					return meta ? json(meta) : error(404, "Not found");
				}
				case "PUT":
					return putMeta(id, request);
				case "DELETE":
					return deleteItem(id);
				default:
					return error(405, "Method not allowed");
			}
		}

		if (parts.length === 4 && parts[3] === "media") {
			switch (request.method) {
				case "GET":
				case "HEAD":
					return getMedia(id, request);
				case "PUT":
					return putMedia(id, request);
				default:
					return error(405, "Method not allowed");
			}
		}

		return error(404, "Not found");
	},
} satisfies ExportedHandler;
