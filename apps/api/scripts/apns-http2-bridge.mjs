#!/usr/bin/env node
import http from "node:http";
import http2 from "node:http2";

const bindHost = process.env.APNS_HTTP2_BRIDGE_HOST || "127.0.0.1";
const port = Number(process.env.APNS_HTTP2_BRIDGE_PORT || 8791);
const allowedOrigins = new Set([
  "https://api.push.apple.com",
  "https://api.sandbox.push.apple.com",
]);

function json(res, statusCode, body) {
  res.writeHead(statusCode, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function tokenExpired(statusCode, reason) {
  return (
    statusCode === 410 ||
    reason === "ExpiredToken" ||
    reason === "BadDeviceToken" ||
    reason === "Unregistered"
  );
}

async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 1024 * 1024) throw new Error("Request body too large");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function sendApns({ host, token, headers, payload }) {
  return new Promise((resolve) => {
    if (!allowedOrigins.has(host)) {
      resolve({
        ok: false,
        statusCode: 400,
        tokenExpired: false,
        detail: `Unsupported APNs host: ${host}`,
      });
      return;
    }

    const client = http2.connect(host);
    const chunks = [];
    let settled = false;
    let statusCode = 0;
    let apnsId;

    const finish = (result) => {
      if (settled) return;
      settled = true;
      client.close();
      resolve(result);
    };

    client.setTimeout(15000, () => {
      finish({
        ok: false,
        statusCode: 0,
        tokenExpired: false,
        detail: "APNs HTTP/2 request timed out",
      });
    });

    client.on("error", (err) => {
      finish({
        ok: false,
        statusCode: 0,
        tokenExpired: false,
        detail: String(err),
      });
    });

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${token}`,
      authorization: headers.authorization,
      "apns-topic": headers["apns-topic"],
      "apns-push-type": headers["apns-push-type"],
      "apns-priority": headers["apns-priority"],
      "content-type": headers["content-type"] || "application/json",
    });

    req.setEncoding("utf8");
    req.on("response", (responseHeaders) => {
      statusCode = Number(responseHeaders[":status"] || 0);
      apnsId = responseHeaders["apns-id"];
    });
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("error", (err) => {
      finish({
        ok: false,
        statusCode: 0,
        tokenExpired: false,
        detail: String(err),
      });
    });
    req.on("end", () => {
      const raw = chunks.join("");
      let reason;
      if (raw) {
        try {
          reason = JSON.parse(raw).reason;
        } catch {
          // Keep the raw body as detail below.
        }
      }
      finish({
        ok: statusCode === 200,
        statusCode,
        apnsId: typeof apnsId === "string" ? apnsId : undefined,
        reason,
        tokenExpired: tokenExpired(statusCode, reason),
        detail: raw || undefined,
      });
    });
    req.end(JSON.stringify(payload));
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method !== "POST" || req.url !== "/send") {
    json(res, 404, { ok: false, detail: "Not found" });
    return;
  }

  try {
    const body = await readJson(req);
    if (
      typeof body.host !== "string" ||
      typeof body.token !== "string" ||
      typeof body.headers?.authorization !== "string" ||
      typeof body.headers?.["apns-topic"] !== "string" ||
      typeof body.headers?.["apns-push-type"] !== "string" ||
      typeof body.payload !== "object" ||
      body.payload === null
    ) {
      json(res, 400, { ok: false, detail: "Invalid APNs bridge request" });
      return;
    }

    json(res, 200, await sendApns(body));
  } catch (err) {
    json(res, 500, {
      ok: false,
      statusCode: 0,
      tokenExpired: false,
      detail: String(err),
    });
  }
});

server.listen(port, bindHost, () => {
  console.log(`[apns-bridge] listening on http://${bindHost}:${port}`);
});
