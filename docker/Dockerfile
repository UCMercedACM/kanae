FROM python:3.13-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  bash \
  git \
  netcat-traditional \
  tini \
  && apt-get clean

WORKDIR /kanae
COPY /server /kanae/server/
COPY /docker/start.sh /kanae/start.sh
COPY /docker/wait-for /kanae/wait-for
COPY /requirements.txt /kanae/requirements.txt

RUN adduser --disabled-password --gecos "" kanae \
  && chown -R kanae:kanae /kanae \
  && chmod +x /kanae/start.sh \
  && chmod +x /kanae/wait-for

USER kanae

ENV PATH="${PATH}:/home/kanae/.local/bin"

RUN pip install --user -r requirements.txt

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/kanae/start.sh"]

STOPSIGNAL SIGTERM

LABEL org.opencontainers.image.title="Kanae"
LABEL org.opencontainers.image.description="Internal backend server for ACM @ UC Merced"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/UCMercedACM/kanae"