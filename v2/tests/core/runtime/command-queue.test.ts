import { describe, it, expect } from "vitest";
import { enqueue, clearLane, isLaneActive, laneQueueLength } from "@druzhok/core/runtime/command-queue.js";

describe("command-queue", () => {
  it("executes tasks in order within a lane", async () => {
    const order: number[] = [];
    await Promise.all([
      enqueue("test-order", async () => { order.push(1); }),
      enqueue("test-order", async () => { order.push(2); }),
      enqueue("test-order", async () => { order.push(3); }),
    ]);
    expect(order).toEqual([1, 2, 3]);
  });

  it("runs different lanes concurrently", async () => {
    const started: string[] = [];
    const finished: string[] = [];

    const a = enqueue("lane-a", async () => {
      started.push("a");
      await new Promise((r) => setTimeout(r, 50));
      finished.push("a");
    });
    const b = enqueue("lane-b", async () => {
      started.push("b");
      await new Promise((r) => setTimeout(r, 10));
      finished.push("b");
    });

    await Promise.all([a, b]);

    // Both should have started before either finished
    expect(started).toContain("a");
    expect(started).toContain("b");
    // b finishes first (10ms vs 50ms)
    expect(finished[0]).toBe("b");
  });

  it("serializes tasks in same lane", async () => {
    const events: string[] = [];

    await Promise.all([
      enqueue("serial-test", async () => {
        events.push("start-1");
        await new Promise((r) => setTimeout(r, 30));
        events.push("end-1");
      }),
      enqueue("serial-test", async () => {
        events.push("start-2");
        events.push("end-2");
      }),
    ]);

    // Task 2 should not start until task 1 ends
    expect(events.indexOf("start-2")).toBeGreaterThan(events.indexOf("end-1"));
  });

  it("returns task result", async () => {
    const result = await enqueue("result-test", async () => 42);
    expect(result).toBe(42);
  });

  it("propagates task errors", async () => {
    await expect(
      enqueue("error-test", async () => { throw new Error("boom"); })
    ).rejects.toThrow("boom");
  });

  it("clearLane rejects queued tasks", async () => {
    const slow = enqueue("clear-test", async () => {
      await new Promise((r) => setTimeout(r, 100));
      return "done";
    });
    const queued = enqueue("clear-test", async () => "should not run");

    clearLane("clear-test");
    await expect(queued).rejects.toThrow("cleared");
    await expect(slow).resolves.toBe("done");
  });

  it("isLaneActive reports correctly", async () => {
    expect(isLaneActive("active-test")).toBe(false);
    const p = enqueue("active-test", async () => {
      await new Promise((r) => setTimeout(r, 50));
    });
    expect(isLaneActive("active-test")).toBe(true);
    await p;
    expect(isLaneActive("active-test")).toBe(false);
  });

  it("laneQueueLength reports queued count", async () => {
    expect(laneQueueLength("ql-test")).toBe(0);
    const slow = enqueue("ql-test", async () => {
      await new Promise((r) => setTimeout(r, 100));
    });
    // slow is running, not queued
    enqueue("ql-test", async () => {}).catch(() => {});
    enqueue("ql-test", async () => {}).catch(() => {});
    expect(laneQueueLength("ql-test")).toBe(2);
    clearLane("ql-test");
    await slow;
  });
});
