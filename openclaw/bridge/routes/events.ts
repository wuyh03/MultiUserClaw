import express from "express";
import type { BridgeGatewayClient, GatewayEvent } from "../gateway-client.js";

type TextContentBlock = {
  type: "text";
  text: string;
  is_delta?: boolean;
};

type ChatDeltaPayload = {
  state: "delta";
  sessionKey?: string;
  message?: {
    content?: unknown;
  };
};

// 50ms throttle interval for delta events
const throttleMs = 50;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function asChatDeltaPayload(payload: GatewayEvent["payload"]): ChatDeltaPayload | null {
  if (!isRecord(payload) || payload.state !== "delta") {
    return null;
  }
  return payload as ChatDeltaPayload;
}

function extractTextBlock(content: unknown): TextContentBlock | null {
  if (!Array.isArray(content)) {
    return null;
  }
  const textPart = content.find(
    (block): block is TextContentBlock =>
      isRecord(block) && block.type === "text" && typeof block.text === "string",
  );
  return textPart ?? null;
}

export function eventsRoutes(client: BridgeGatewayClient) {
  const router = express.Router();

  router.get("/events/stream", (_req, res) => {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });

    // Send initial keepalive
    res.write(": connected\n\n");

    // Per-connection state (avoids cross-connection interference)
    let connLastSendTime = 0;
    let connThrottledBuffer: GatewayEvent | null = null;
    let connThrottleTimer: NodeJS.Timeout | null = null;
    const connTextState = new Map<string, string>();

    function connTransformDeltaEvent(evt: GatewayEvent): GatewayEvent {
      if (evt.event !== "chat") return evt;
      const payload = asChatDeltaPayload(evt.payload);
      if (!payload) return evt;
      const sk = payload.sessionKey ?? "";
      const textPart = extractTextBlock(payload.message?.content);
      if (!textPart) return evt;
      const prev = connTextState.get(sk) || "";
      const delta = textPart.text.slice(prev.length);
      connTextState.set(sk, textPart.text);
      return {
        ...evt,
        payload: {
          ...payload,
          message: { ...payload.message, content: [{ type: "text" as const, text: delta, is_delta: true }] },
        },
      };
    }

    const listener = (evt: GatewayEvent) => {
      if (evt.event === "chat") {
        const state = isRecord(evt.payload) ? evt.payload.state : undefined;

        // Clear per-connection session state on started to reset for new turns
        if (state === "started") {
          const sessionKey = typeof evt.payload.sessionKey === "string" ? evt.payload.sessionKey : "";
          if (sessionKey) {
            connTextState.delete(sessionKey);
          }
        }

        // Critical state events must be sent immediately, never throttled.
        // Throttling these can cause them to be lost (overwritten in buffer),
        // which leaves the frontend stuck in "sending" state forever.
        if (state === "started" || state === "final" || state === "error" || state === "aborted") {
          // Flush any buffered delta first so ordering is preserved
          if (connThrottledBuffer) {
            res.write(`data: ${JSON.stringify(connThrottledBuffer)}\n\n`);
            connThrottledBuffer = null;
          }
          if (connThrottleTimer) {
            clearTimeout(connThrottleTimer);
            connThrottleTimer = null;
          }
          res.write(`data: ${JSON.stringify(evt)}\n\n`);
          connLastSendTime = Date.now();
          return;
        }

        // Transform delta to send increments instead of full text (per-connection)
        const transformedEvt = connTransformDeltaEvent(evt);

        // Apply 50ms throttling to delta events only
        const now = Date.now();
        if (now - connLastSendTime >= throttleMs) {
          res.write(`data: ${JSON.stringify(transformedEvt)}\n\n`);
          connLastSendTime = now;
          connThrottledBuffer = null;
          if (connThrottleTimer) {
            clearTimeout(connThrottleTimer);
            connThrottleTimer = null;
          }
        } else {
          connThrottledBuffer = transformedEvt;
          if (!connThrottleTimer) {
            connThrottleTimer = setTimeout(() => {
              if (connThrottledBuffer) {
                res.write(`data: ${JSON.stringify(connThrottledBuffer)}\n\n`);
                connLastSendTime = Date.now();
              }
              connThrottledBuffer = null;
              connThrottleTimer = null;
            }, throttleMs);
          }
        }
      } else if (evt.event === 'agent') {
        // Forward agent events as-is
        res.write(`data: ${JSON.stringify(evt)}\n\n`);
      }
    };

    client.onEvent(listener);

    // Keepalive every 25s to prevent proxy timeouts
    const keepalive = setInterval(() => {
      res.write(": keepalive\n\n");
    }, 25000);

    _req.on("close", () => {
      clearInterval(keepalive);
      if (connThrottleTimer) {
        clearTimeout(connThrottleTimer);
      }
      client.offEvent(listener);
    });
  });

  return router;
}
