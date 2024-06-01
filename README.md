[![pipeline status](https://gitlab.conarx.tech/containers/mattermost/badges/main/pipeline.svg)](https://gitlab.conarx.tech/containers/mattermost/-/commits/main)

# Container Information

[Container Source](https://gitlab.conarx.tech/containers/mattermost) - [GitHub Mirror](https://github.com/AllWorldIT/containers-mattermost)

This is the Conarx Containers Minio image, it provides the Minio S3 server and Minio Client within the same Docker image.



# Mirrors

|  Provider  |  Repository                                 |
|------------|---------------------------------------------|
| DockerHub  | allworldit/mattermost                       |
| Conarx     | registry.conarx.tech/containers/mattermost  |



# Conarx Containers

All our Docker images are part of our Conarx Containers product line. Images are generally based on Alpine Linux and track the
Alpine Linux major and minor version in the format of `vXX.YY`.

Images built from source track both the Alpine Linux major and minor versions in addition to the main software component being
built in the format of `vXX.YY-AA.BB`, where `AA.BB` is the main software component version.

Our images are built using our Flexible Docker Containers framework which includes the below features...

- Flexible container initialization and startup
- Integrated unit testing
- Advanced multi-service health checks
- Native IPv6 support for all containers
- Debugging options



# Community Support

Please use the project [Issue Tracker](https://gitlab.conarx.tech/containers/mattermost/-/issues).



# Commercial Support

Commercial support for all our Docker images is available from [Conarx](https://conarx.tech).

We also provide consulting services to create and maintain Docker images to meet your exact needs.



# Environment Variables

Additional environment variables are available from...
* [Conarx Containers Postfix image](https://gitlab.conarx.tech/containers/postfix)
* [Conarx Containers Alpine image](https://gitlab.conarx.tech/containers/alpine)


## MATTERMOST_DATABASE_TYPE

Mattermost database type, either `mariadb`, `mysql` or `postgresql`.

## MYSQL_HOST, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD

Database credentials if `MATTERMOST_DATABASE_TYPE` is set to `mariadb` or `mysql`.

## POSTGRES_HOST, POSTGRES_DATABASE, POSTGRES_USER, POSTGRES_PASSWORD

Database credentials if `MATTERMOST_DATABASE_TYPE` is set to `postgresql`.



# Configuration

Configuration files of note can be found below...

| Path                                                         | Description                                               |
|--------------------------------------------------------------|-----------------------------------------------------------|
| /etc/mattermost/config.d                                     | Mattermost configuration                                  |
| /etc/mattermost/config.d/NN-*.json                           | Mattermost configuration files                            |

The configuration file is constructed from files within the config.d directory by lexically merging each file.

One could mount over the config.d directory or mount a configuration file within this directory.


# Volumes

## /etc/mattermost/config

Mattermost config directory.

## /var/lib/mattermost

Mattermost data directory.



# Exposed Ports

Mattermost port 8080 is exposed.



# Configuration Exampmle


```yaml
services:

  mattermost:
    image: registry.conarx.tech/containers/mattermost
    environment:
      - MATTERMOST_DATABASE_TYPE=mysql
      - MYSQL_HOST=mariadb-server
      - MYSQL_DATABASE=mattermost
      - MYSQL_USER=mattermost
      - MYSQL_PASSWORD=mattermost
    volumes:
      - ./data/mattermost:/var/lib/mattermost
      - ./data/mattermost-config:/etc/mattermost/config
    networks:
      - external

  mariadb-server:
    image: registry.conarx.tech/containers/mariadb
    environment:
      - MYSQL_DATABASE=mattermost
      - MYSQL_USER=mattermost
      - MYSQL_PASSWORD=mattermost
    volumes:
      - ./data/mariadb:/var/lib/mysql
    networks:
      - external

networks:
  internal:
    driver: bridge
    enable_ipv6: true
```