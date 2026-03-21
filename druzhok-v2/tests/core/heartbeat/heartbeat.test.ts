import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createHeartbeatManager } from "@druzhok/core/heartbeat/heartbeat.js";

describe("createHeartbeatManager", () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it("calls onTick at configured interval", () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const m = createHeartbeatManager({ intervalMs: 1000, readHeartbeatMd: () => "- Check builds", onTick });
    m.start();
    vi.advanceTimersByTime(1000);
    expect(onTick).toHaveBeenCalledTimes(1);
    m.stop();
  });
  it("skips tick when HEARTBEAT.md is empty", () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const m = createHeartbeatManager({ intervalMs: 1000, readHeartbeatMd: () => "# Heartbeat\n", onTick });
    m.start();
    vi.advanceTimersByTime(1000);
    expect(onTick).not.toHaveBeenCalled();
    m.stop();
  });
  it("runs tick when HEARTBEAT.md is missing (null)", () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const m = createHeartbeatManager({ intervalMs: 1000, readHeartbeatMd: () => null, onTick });
    m.start();
    vi.advanceTimersByTime(1000);
    expect(onTick).toHaveBeenCalledTimes(1);
    m.stop();
  });
  it("skips tick when previous is still running", () => {
    let resolve: () => void;
    const firstCall = new Promise<void>((r) => { resolve = r; });
    const onTick = vi.fn().mockReturnValueOnce(firstCall).mockResolvedValue(undefined);
    const m = createHeartbeatManager({ intervalMs: 1000, readHeartbeatMd: () => "- task", onTick });
    m.start();
    vi.advanceTimersByTime(1000);
    vi.advanceTimersByTime(1000);
    expect(onTick).toHaveBeenCalledTimes(1);
    resolve!();
    m.stop();
  });
  it("stop clears the timer", () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const m = createHeartbeatManager({ intervalMs: 1000, readHeartbeatMd: () => "- task", onTick });
    m.start();
    m.stop();
    vi.advanceTimersByTime(5000);
    expect(onTick).not.toHaveBeenCalled();
  });
});
