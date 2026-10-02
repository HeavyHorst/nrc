// =============================================================================
// LATENCY MEASUREMENT WEB WORKER
// =============================================================================
// Offloads latency/jitter calculations from main thread to reduce jitter

const MAX_LATENCY_HISTORY = 50;
const LATENCY_STABILITY_THRESHOLD = 20; // ms standard deviation
const RFC_3550_WEIGHT = 1/16; // Exponential smoothing weight

let latencyHistory = [];
let currentLatency = null;
let latencyStabilityState = "stable";
let smoothedJitter = 0; // RFC 3550 exponentially smoothed jitter
let lastLatencyTimestamp = null; // Timestamp of last pong received

// Handle messages from main thread
self.onmessage = function (e) {
  const { type, data } = e.data;

  switch (type) {
    case "addLatency":
      processLatency(data.latencyMs);
      break;
    case "reset":
      latencyHistory = [];
      currentLatency = null;
      latencyStabilityState = "stable";
      smoothedJitter = 0;
      lastLatencyTimestamp = null;
      break;
  }
};

function processLatency(latencyMs) {
  currentLatency = latencyMs;

  // RFC 3550 jitter calculation
  // Jitter = exponentially smoothed difference between expected and actual interarrival times
  const now = Date.now();
  if (lastLatencyTimestamp !== null) {
    const actualInterarrival = now - lastLatencyTimestamp;
    const expectedInterarrival = 5000; // Ping interval in milliseconds
    const delta = Math.abs(actualInterarrival - expectedInterarrival);
    
    // Exponential smoothing: J = J + (|D| - J) * WEIGHT
    smoothedJitter = smoothedJitter + (delta - smoothedJitter) * RFC_3550_WEIGHT;
  }
  lastLatencyTimestamp = now;

  // Add to history
  latencyHistory.push(latencyMs);
  if (latencyHistory.length > MAX_LATENCY_HISTORY) {
    latencyHistory.shift();
  }

  // Calculate stats and send back to main thread
  const stats = calculateStats();
  self.postMessage({ type: "stats", data: stats });
}

function calculateStats() {
  const stats = {
    current: currentLatency,
    avg: 0,
    p95: 0,
    jitterAvg: Math.round(smoothedJitter), // RFC 3550 exponentially smoothed jitter
    jitterP95: 0, // Not applicable for RFC 3550
    stabilityState: latencyStabilityState,
  };

  if (latencyHistory.length > 0) {
    // Average latency
    const sum = latencyHistory.reduce((a, b) => a + b, 0);
    stats.avg = Math.round(sum / latencyHistory.length);

    // P95 latency
    const sorted = [...latencyHistory].sort((a, b) => a - b);
    const p95Index = Math.min(
      Math.floor(sorted.length * 0.95),
      sorted.length - 1,
    );
    stats.p95 = sorted[p95Index];
  }

  // Check stability
  if (latencyHistory.length >= 10) {
    const n = latencyHistory.length;
    const mean = latencyHistory.reduce((a, b) => a + b, 0) / n;
    const variance =
      latencyHistory.reduce((a, b) => a + Math.pow(b - mean, 2), 0) / n;
    const stdDev = Math.sqrt(variance);

    const newState = stdDev > LATENCY_STABILITY_THRESHOLD ? "degraded" : "stable";
    if (newState !== latencyStabilityState) {
      latencyStabilityState = newState;
      stats.stabilityChanged = true;
    }
    stats.stabilityState = latencyStabilityState;
  }

  return stats;
}
