// Copies the README screenshots and the app icon into public/, so the site never holds a second copy in git.
import { copyFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(web, "..");

const shots = join(repo, "docs", "screenshots");
const out = join(web, "public", "screenshots");
mkdirSync(out, { recursive: true });
for (const name of readdirSync(shots)) {
  if (/\.(png|gif|jpe?g|webp)$/.test(name)) copyFileSync(join(shots, name), join(out, name));
}
copyFileSync(join(repo, "Resources", "icon-1024.png"), join(web, "public", "icon.png"));
