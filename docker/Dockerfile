FROM python:3.13-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  tini \
  && apt-get clean

WORKDIR /kanae
COPY /server /kanae/server/
COPY /requirements.txt /kanae/requirements.txt

RUN adduser --disabled-password --gecos "" kanae \
  && chown -R kanae:kanae /kanae

USER kanae

ENV PATH="${PATH}:/home/kanae/.local/bin"

RUN pip install --user -r requirements.txt

EXPOSE 8000
EXPOSE 9555

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["python3", "/kanae/server/launcher.py", "--no-workers"]

STOPSIGNAL SIGTERM

LABEL org.opencontainers.image.title="Kanae"
LABEL org.opencontainers.image.description="Internal backend server for ACM @ UC Merced"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/UCMercedACM/kanae"
