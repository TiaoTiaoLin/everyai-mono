# The dev backend as a container. The binary is cross-compiled outside
# (deploy.sh) and is the only file sent with this Dockerfile, so no .env or
# key can end up in the image.
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY everyai-backend-exp /app/everyai-backend-exp
VOLUME /app/data
# Dev build: dev auth (no sign-in), no server keys, users bring their own keys.
ENV ANOLE_ENV=development \
    HOST=0.0.0.0 \
    PORT=8443 \
    DEV_AUTH=true \
    DEV_AUTH_LAN=true \
    DATABASE_PATH=data/everyai.db \
    RATE_LIMIT_PER_MINUTE=600
EXPOSE 8443
ENTRYPOINT ["/app/everyai-backend-exp"]
