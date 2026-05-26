# Kanae

[![CodeQL](https://github.com/UCMercedACM/kanae/actions/workflows/codeql.yml/badge.svg)](https://github.com/UCMercedACM/kanae/actions/workflows/codeql.yml) [![Lint](https://github.com/UCMercedACM/kanae/actions/workflows/lint.yml/badge.svg)](https://github.com/UCMercedACM/kanae/actions/workflows/lint.yml) [![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=UCMercedACM_kanae&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=UCMercedACM_kanae) [![Lines of Code](https://sonarcloud.io/api/project_badges/measure?project=UCMercedACM_kanae&metric=ncloc)](https://sonarcloud.io/summary/new_code?id=UCMercedACM_kanae)

Association for Computing Machinery at UC Merced's backend web server

> [!IMPORTANT]
> We would prefer if you do not run instances of Kanae (included self-hosted ones). This API is semi-public, thus the source code is provided as-is and is for educational and development purposes only.

## What is Kanae?

Kanae is the backend web server for ACM at UC Merced. It aims to be the main backend server used for handling
requests related to the club's information. In addition, Kanae is designed to entirely replace the
old microservices ([Half-Dome](https://github.com/UCMercedACM/Half-Dome), [Cathedral](https://github.com/UCMercedACM/Cathedral), etc)
by containing them into one monolithic application.

Public data can be queried without authentication, but most of the endpoints are locked behind an authentication layer.

## Contributing

Contributions to Kanae are always welcomed. Although there is an dedicated development team solely focused on building the website, changes from others are always appreciated.
These could be as small as changing documentation to adding new features. If you are interested to start the process, please consult the [contributing guidelines](.github/CONTRIBUTING.md) before you get started.
