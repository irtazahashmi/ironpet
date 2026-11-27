import { site } from "./site";

export type Release = {
  version: string | null;
  dmgUrl: string;
  notesUrl: string;
};

const fallback: Release = { version: null, dmgUrl: `${site.releases}/latest`, notesUrl: `${site.releases}/latest` };

type GitHubRelease = { tag_name: string; html_url: string; assets: { name: string; browser_download_url: string }[] };

/** The latest published release, read once at build time. Falls back to the Releases page when GitHub can't be reached. */
export async function latestRelease(): Promise<Release> {
  try {
    const res = await fetch("https://api.github.com/repos/irtazahashmi/ironpet/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
      cache: "force-cache",
    });
    if (!res.ok) return fallback;
    const release = (await res.json()) as GitHubRelease;
    const dmgs = release.assets.filter((a) => a.name.endsWith(".dmg"));
    const dmg = dmgs.find((a) => !a.name.includes("unsigned")) ?? dmgs[0];
    return {
      version: release.tag_name.replace(/^v/, ""),
      dmgUrl: dmg?.browser_download_url ?? release.html_url,
      notesUrl: release.html_url,
    };
  } catch {
    return fallback;
  }
}
