/**
 * Lane-based command queue. Tasks in the same lane are serialized (FIFO).
 * Different lanes run concurrently.
 */

type QueueEntry<T = unknown> = {
  task: () => Promise<T>;
  resolve: (value: T) => void;
  reject: (reason?: unknown) => void;
};

type LaneState = {
  queue: QueueEntry[];
  running: number;
  maxConcurrent: number;
};

const lanes = new Map<string, LaneState>();

const DEFAULT_MAX_CONCURRENT: Record<string, number> = {
  main: 1,
  cron: 1,
  subagent: 3,
};

function getLane(name: string): LaneState {
  let lane = lanes.get(name);
  if (!lane) {
    lane = {
      queue: [],
      running: 0,
      maxConcurrent: DEFAULT_MAX_CONCURRENT[name] ?? 1,
    };
    lanes.set(name, lane);
  }
  return lane;
}

function drain(lane: LaneState): void {
  while (lane.queue.length > 0 && lane.running < lane.maxConcurrent) {
    const entry = lane.queue.shift()!;
    lane.running++;
    entry.task().then(
      (value) => {
        lane.running--;
        entry.resolve(value);
        drain(lane);
      },
      (err) => {
        lane.running--;
        entry.reject(err);
        drain(lane);
      },
    );
  }
}

/**
 * Enqueue a task in a named lane. Returns a promise that resolves
 * when the task completes.
 */
export function enqueue<T>(laneName: string, task: () => Promise<T>): Promise<T> {
  const lane = getLane(laneName);
  return new Promise<T>((resolve, reject) => {
    lane.queue.push({ task, resolve, reject } as QueueEntry);
    drain(lane);
  });
}

/**
 * Clear all queued (not running) tasks in a lane.
 * Running tasks are not affected.
 */
export function clearLane(laneName: string): void {
  const lane = lanes.get(laneName);
  if (!lane) return;
  for (const entry of lane.queue) {
    entry.reject(new Error(`Lane "${laneName}" cleared`));
  }
  lane.queue = [];
}

/**
 * Check if a lane has running or queued tasks.
 */
export function isLaneActive(laneName: string): boolean {
  const lane = lanes.get(laneName);
  if (!lane) return false;
  return lane.running > 0 || lane.queue.length > 0;
}

/**
 * Get the number of queued tasks in a lane.
 */
export function laneQueueLength(laneName: string): number {
  return lanes.get(laneName)?.queue.length ?? 0;
}
