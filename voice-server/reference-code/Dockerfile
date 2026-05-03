FROM oven/bun:1

WORKDIR /app

COPY package.json ./
RUN bun install

COPY src ./src

EXPOSE 8888 8889

CMD ["bun", "run", "src/server.ts"]
