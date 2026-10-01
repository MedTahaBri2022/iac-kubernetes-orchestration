FROM node:22-alpine

# The version is baked into the image: v1 and v2 are two different images,
# which is what a rolling update replaces.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    NODE_ENV=production \
    PORT=8080

WORKDIR /app
COPY package.json server.js ./

# Do not run as root inside the container.
USER node
EXPOSE 8080

CMD ["node", "server.js"]
