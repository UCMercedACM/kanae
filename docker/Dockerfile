FROM python:3.13-slim-trixie

ENV DEBIAN_FRONTEND=noninteractive
ENV TINI_VERSION=v0.19.0

ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini

WORKDIR /kanae
COPY /server /kanae/server/
COPY /requirements.txt /kanae/requirements.txt

RUN adduser --disabled-password --gecos "" kanae \
  && chown -R kanae:kanae /kanae

USER kanae

ENV PATH="${PATH}:/home/kanae/.local/bin"

RUN pip install --user -r requirements.txt

EXPOSE 8000

ENTRYPOINT ["/tini", "--"]

CMD ["python3", "/kanae/server/launcher.py"]

STOPSIGNAL SIGTERM

LABEL org.opencontainers.image.title="Kanae"
LABEL org.opencontainers.image.description="Internal backend server for ACM @ UC Merced"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/UCMercedACM/kanae"
