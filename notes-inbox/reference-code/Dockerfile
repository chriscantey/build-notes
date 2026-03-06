FROM oven/bun:1-alpine

WORKDIR /app

COPY package.json ./
RUN bun install --frozen-lockfile 2>/dev/null || true

COPY server.ts ./

CMD ["bun", "run", "server.ts"]
