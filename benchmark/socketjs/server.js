const http = require("node:http");
const jwt = require("jsonwebtoken");
const { Server } = require("socket.io");

const port = Number(process.env.PORT || 8081);
const enableAuth = process.env.AUTH_ENABLED === "1";
const jwtSecret = process.env.NRC_JWT_SECRET || "dev-insecure-nrc-jwt-secret";
const jwtIssuer = process.env.JWT_ISSUER || "nrc-tailscale-proxy";
const jwtAudience = process.env.JWT_AUDIENCE || "nrc";

const server = http.createServer();
const io = new Server(server, {
  transports: ["websocket"],
  cors: { origin: "*" },
});

io.use((socket, next) => {
  if (!enableAuth) {
    return next();
  }

  const token = socket.handshake.headers["x-nrc-auth"];
  if (!token || typeof token !== "string") {
    return next(new Error("missing x-nrc-auth header"));
  }

  try {
    const claims = jwt.verify(token, jwtSecret, {
      algorithms: ["HS256"],
      issuer: jwtIssuer,
      audience: jwtAudience,
    });
    socket.data.username = claims.username || claims.sub || "unknown";
    return next();
  } catch (err) {
    return next(new Error(`invalid auth token: ${err.message}`));
  }
});

io.on("connection", (socket) => {
  const workspace = String(socket.handshake.auth?.workspace || socket.handshake.query?.workspace || "ws-0");
  socket.data.workspace = workspace;

  socket.on("subscribe_convs", (payload = {}) => {
    const convIDs = Array.isArray(payload.convIDs) ? payload.convIDs : [];
    for (const convID of convIDs) {
      socket.join(`${workspace}:${convID}`);
    }
  });

  socket.on("send_message", (payload = {}, ack) => {
    const convID = payload.convID;
    const room = `${workspace}:${convID}`;
    const event = {
      convID,
      clientReqID: payload.clientReqID,
      username: socket.data.username || payload.username || "anon",
      timestamp: Date.now(),
      content: payload.content || "",
    };

    io.to(room).emit("new_message", event);
    if (typeof ack === "function") {
      ack({ clientReqID: payload.clientReqID, timestamp: Date.now() });
    }
  });
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`socketjs benchmark server listening on :${port}\n`);
});
