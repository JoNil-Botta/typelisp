export class Stage0HttpError extends Error {
  constructor(readonly status: number, url: string) {
    super(`HTTP ${status} for ${url}`);
  }
}

type GetText = (url: string) => Promise<string>;

export function stage0BaseUrl(repo: string, tag: string): string {
  return `https://github.com/${repo}/releases/download/${tag}`;
}

// Permanent generations append to the newest-first listing. Stop at its first
// usable page instead of exhausting GitHub's historical pagination cap. The
// comparison resolves the tag itself, so moved tags cannot borrow ancestry.
export async function immutableMainRelease(repo: string, asset: string, get: GetText): Promise<string> {
  const api = `https://api.github.com/repos/${repo}`;
  for (let page = 1; ; page += 1) {
    const candidates: { tag: string; sha: string; published: string }[] = [];
    const records: unknown = JSON.parse(await get(`${api}/releases?per_page=100&page=${page}`));
    if (!Array.isArray(records)) throw new Error('invalid stage0 release list');
    for (const record of records) {
      if (record?.draft !== false || record.prerelease !== false ||
          typeof record.published_at !== 'string' || !record.published_at ||
          typeof record.tag_name !== 'string' || !/^stage0-[0-9]{8}-[0-9]{6}-r[0-9]+$/.test(record.tag_name) ||
          typeof record.target_commitish !== 'string' || !/^[0-9a-f]{40}$/.test(record.target_commitish) ||
          !Array.isArray(record.assets)) continue;
      const uploaded = (name: string) => record.assets.some((entry: { name?: unknown; state?: unknown; size?: unknown }) =>
        entry?.name === name && entry.state === 'uploaded' && typeof entry.size === 'number' && entry.size > 0);
      if (uploaded(asset) && uploaded('SHA256SUMS')) candidates.push({ tag: record.tag_name, sha: record.target_commitish, published: record.published_at });
    }
    candidates.sort((a, b) => a.published < b.published ? 1 : a.published > b.published ? -1 : a.tag < b.tag ? 1 : a.tag > b.tag ? -1 : 0);
    for (const candidate of candidates) {
      let comparison;
      try {
        comparison = JSON.parse(await get(`${api}/compare/${candidate.tag}...main`));
      } catch (error) {
        if (error instanceof Stage0HttpError && error.status === 404) continue;
        throw error;
      }
      if (comparison?.base_commit?.sha === candidate.sha && ['ahead', 'identical'].includes(comparison.status)) {
        return candidate.tag;
      }
    }
    if (records.length < 100) break;
  }
  throw new Error(`no published immutable main release with ${asset} and SHA256SUMS`);
}

export function expectedHashFor(sums: string, asset: string): string | undefined {
  for (const line of sums.split(/\r?\n/)) {
    const match = line.match(/^([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$/);
    if (match && match[2] === asset) return match[1].toLowerCase();
  }
  return undefined;
}
