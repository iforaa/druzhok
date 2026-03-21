export type SearchResult = { id: string; score: number; text: string; file: string; startLine: number; endLine: number };
type MergeWeights = { vectorWeight: number; textWeight: number };

export function mergeSearchResults(vectorResults: SearchResult[], keywordResults: SearchResult[], weights: MergeWeights): SearchResult[] {
  const total = weights.vectorWeight + weights.textWeight;
  const vw = weights.vectorWeight / total;
  const tw = weights.textWeight / total;
  const merged = new Map<string, SearchResult>();
  for (const r of vectorResults) merged.set(r.id, { ...r, score: r.score * vw });
  for (const r of keywordResults) {
    const existing = merged.get(r.id);
    if (existing) existing.score += r.score * tw;
    else merged.set(r.id, { ...r, score: r.score * tw });
  }
  return [...merged.values()].sort((a, b) => b.score - a.score);
}

type DecayOpts = { halfLifeDays: number };
function extractDateFromPath(file: string): Date | null { const match = file.match(/(\d{4}-\d{2}-\d{2})\.md$/); return match ? new Date(match[1]) : null; }
function isEvergreen(file: string): boolean { return file.endsWith("MEMORY.md") || !extractDateFromPath(file); }

export function applyTemporalDecay(results: SearchResult[], opts: DecayOpts): SearchResult[] {
  const now = new Date();
  const lambda = Math.LN2 / opts.halfLifeDays;
  return results.map((r) => {
    if (isEvergreen(r.file)) return r;
    const fileDate = extractDateFromPath(r.file);
    if (!fileDate) return r;
    const todayStr = now.toISOString().slice(0, 10);
    const fileDateStr = fileDate.toISOString().slice(0, 10);
    const msPerDay = 1000 * 60 * 60 * 24;
    const ageInDays = todayStr === fileDateStr ? 0 : (now.getTime() - fileDate.getTime()) / msPerDay;
    return { ...r, score: r.score * Math.exp(-lambda * Math.max(0, ageInDays)) };
  });
}

type MMROpts = { lambda: number; maxResults: number };
function jaccardSimilarity(a: string, b: string): number {
  const tokensA = new Set(a.toLowerCase().split(/\W+/).filter(Boolean));
  const tokensB = new Set(b.toLowerCase().split(/\W+/).filter(Boolean));
  if (tokensA.size === 0 && tokensB.size === 0) return 1;
  let intersection = 0;
  for (const t of tokensA) if (tokensB.has(t)) intersection++;
  const union = tokensA.size + tokensB.size - intersection;
  return union === 0 ? 0 : intersection / union;
}

export function applyMMR(results: SearchResult[], opts: MMROpts): SearchResult[] {
  if (results.length <= 1) return results;
  const selected: SearchResult[] = [];
  const remaining = [...results];
  selected.push(remaining.shift()!);
  while (selected.length < opts.maxResults && remaining.length > 0) {
    let bestIdx = 0, bestScore = -Infinity;
    for (let i = 0; i < remaining.length; i++) {
      const candidate = remaining[i];
      let maxSim = 0;
      for (const s of selected) { const sim = jaccardSimilarity(candidate.text, s.text); if (sim > maxSim) maxSim = sim; }
      const mmrScore = opts.lambda * candidate.score - (1 - opts.lambda) * maxSim;
      if (mmrScore > bestScore) { bestScore = mmrScore; bestIdx = i; }
    }
    selected.push(remaining.splice(bestIdx, 1)[0]);
  }
  return selected;
}
