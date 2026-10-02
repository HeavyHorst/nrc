FROM node:24-alpine AS client-build
WORKDIR /build/client
COPY client/package.json client/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY client/ ./
RUN npm run build

FROM alpine:3.23
# Install Nginx and its ABI-matched Brotli module from the same repository.
RUN apk add --no-cache nginx nginx-mod-http-brotli \
    && mkdir -p /run/nginx \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log
COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --from=client-build /build/client/dist/ /usr/share/nginx/html/
EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
