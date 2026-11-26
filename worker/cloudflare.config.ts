import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "stash-api",
		compatibilityDate: "2026-09-25",
		entrypoint,
		env: {
			// Media blobs live under `media/<id>`, metadata JSON under `meta/<id>.json`.
			STASH: bindings.r2({ name: "stash-media" }),
			// Shared bearer token the iOS app sends. Set with the secrets command; locally via .dev.vars.
			API_TOKEN: bindings.secret(),
		},
	},
});
