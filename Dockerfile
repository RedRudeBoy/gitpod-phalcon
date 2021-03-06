# Using bionic instead of disco
FROM buildpack-deps:bionic

### base ###
RUN yes | unminimize \
    && apt-get install -yq \
        asciidoctor \
        bash-completion \
        build-essential \
        htop \
        jq \
        less \
        locales \
        man-db \
        nano \
        software-properties-common \
        sudo \
        vim \
        multitail \
        lsof \
    && locale-gen en_US.UTF-8 \
    && mkdir /var/lib/apt/dazzle-marks \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

ENV LANG=en_US.UTF-8

### Gitpod user ###
# '-l': see https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#user
RUN useradd -l -u 33333 -G sudo -md /home/gitpod -s /bin/bash -p gitpod gitpod \
    # passwordless sudo for users in the 'sudo' group
    && sed -i.bkp -e 's/%sudo\s\+ALL=(ALL\(:ALL\)\?)\s\+ALL/%sudo ALL=NOPASSWD:ALL/g' /etc/sudoers
ENV HOME=/home/gitpod
WORKDIR $HOME
# custom Bash prompt
RUN { echo && echo "PS1='\[\e]0;\u \w\a\]\[\033[01;32m\]\u\[\033[00m\] \[\033[01;34m\]\w\[\033[00m\] \\\$ '" ; } >> .bashrc

### Gitpod user (2) ###
USER gitpod
# use sudo so that user does not get sudo usage info on (the first) login
RUN sudo echo "Running 'sudo' for Gitpod: success"
# create .bashrc.d folder and source it in the bashrc
#RUN mkdir /home/gitpod/.bashrc.d && \
#    (echo; echo "for i in \$(ls \$HOME/.bashrc.d/*); do source \$i; done"; echo) >> /home/gitpod/.bashrc
    
### Apache, PHP and Nginx ###
LABEL dazzle/layer=tool-nginx
LABEL dazzle/test=tests/lang-php.yaml
USER root
RUN  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -yq \
        apache2 \
        nginx \
        nginx-extras \
        composer \
        php \
        php-all-dev \
        php-ctype \
        php-curl \
        php-date \
        php-gd \
        php-gettext \
        php-intl \
        php-json \
        php-mbstring \
        php-mysql \
        php-net-ftp \
        php-pgsql \
        php-sqlite3 \
        php-tokenizer \
        php-xml \
        php-zip \
    && cp /var/lib/dpkg/status /var/lib/apt/dazzle-marks/tool-nginx.status \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* \
    && mkdir /var/run/nginx \
    && ln -s /etc/apache2/mods-available/rewrite.load /etc/apache2/mods-enabled/rewrite.load \
    && chown -R gitpod:gitpod /etc/apache2 /var/run/apache2 /var/lock/apache2 /var/log/apache2 \
    && chown -R gitpod:gitpod /etc/nginx /var/run/nginx /var/lib/nginx/ /var/log/nginx/
COPY --chown=gitpod:gitpod apache2/ /etc/apache2/
COPY --chown=gitpod:gitpod nginx /etc/nginx/

## The directory relative to your git repository that will be served by Apache / Nginx
ENV APACHE_DOCROOT_IN_REPO="public"
ENV NGINX_DOCROOT_IN_REPO="public"

### Install Phalcon ###
USER root
ENV DEBIAN_FRONTEND noninteractive

# Official method not working
#RUN curl -s "https://packagecloud.io/install/repositories/phalcon/stable/script.deb.sh" | bash

RUN add-apt-repository ppa:ondrej/php && \
    add-apt-repository ppa:ondrej/apache2 && \
    curl -L https://packagecloud.io/phalcon/stable/gpgkey | sudo apt-key add - && \
    #`lsb_release -cs` -> bionic / `lsb_release -is` -> Ubuntu
    sh -c 'echo "deb https://packagecloud.io/phalcon/stable/ubuntu/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/phalcon_stable.list' && \
    sh -c 'echo "deb-src https://packagecloud.io/phalcon/stable/ubuntu/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/phalcon_stable.list' && \
#    echo "deb https://packagecloud.io/phalcon/stable/ubuntu/ disco main" > /etc/apt/sources.list.d/phalcon_stable.list && \
#    echo "deb-src https://packagecloud.io/phalcon/stable/ubuntu/ disco main" >> /etc/apt/sources.list.d/phalcon_stable.list && \
    apt-get update && apt-get install -y apt-utils gcc libpcre3-dev software-properties-common curl gnupg apt-transport-https && \
#   apt-get dist-upgrade -y && apt-get autoremove -y && apt-get clean && \
    apt-get update && \
    apt-get install -y php php-curl php-gd php-json php-mbstring && \
#    apt-cache search phalcon* && \
#    apt-cache search php-ph* && \
    apt-get dist-upgrade -y && \
    apt-get install -y php-phalcon4 && \
    apt-get autoremove -y && apt-get autoclean
#   && rm -rf /var/lib/apt/lists/*

### PostgreSQL ###
LABEL dazzle/layer=postgresql
USER gitpod
RUN sudo apt-get update \
 && sudo apt-get install -y postgresql postgresql-contrib postgresql-client-common \
 && sudo apt-get clean
#&& sudo rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/*

## Setup PostgreSQL server for user gitpod
ENV PG_VERSION=10
ENV PATH="$PATH:/usr/lib/postgresql/$PG_VERSION/bin"
ENV PGDATA="/home/gitpod/.pg_ctl/data"
RUN mkdir -p ~/.pg_ctl/bin ~/.pg_ctl/data ~/.pg_ctl/sockets \
 && initdb -D ~/.pg_ctl/data/ \
 && printf "#!/bin/bash\npg_ctl -D ~/.pg_ctl/data/ -l ~/.pg_ctl/log -o \"-k ~/.pg_ctl/sockets\" start\n" > ~/.pg_ctl/bin/pg_start \
 && printf "#!/bin/bash\npg_ctl -D ~/.pg_ctl/data/ -l ~/.pg_ctl/log -o \"-k ~/.pg_ctl/sockets\" stop\n" > ~/.pg_ctl/bin/pg_stop \
 && chmod +x ~/.pg_ctl/bin/*
ENV PATH="$PATH:$HOME/.pg_ctl/bin"
ENV DATABASE_URL="postgresql://gitpod@localhost"
ENV PGHOSTADDR="127.0.0.1"
ENV PGDATABASE="postgres"

# This is a bit of a hack. At the moment we have no means of starting background
# tasks from a Dockerfile. This workaround checks, on each bashrc eval, if the
# PostgreSQL server is running, and if not starts it.
RUN printf "\n# Auto-start PostgreSQL server.\n[[ \$(pg_ctl status | grep PID) ]] || pg_start > /dev/null\n" >> ~/.bashrc

### OpenAPI ###
#LABEL dazzle/layer=openapi
#ARG OPENAPI_GENERATOR_VERSION=3.3.4
#ARG OPENAPI_PATH=/home/gitpod/bin/openapitools
#USER gitpod
#RUN mkdir -p "$OPENAPI_PATH" && \
#    curl https://raw.githubusercontent.com/OpenAPITools/openapi-generator/master/bin/utils/openapi-generator-cli.sh > "$OPENAPI_PATH/openapi-generator-cli" && \
#    chmod u+x "$OPENAPI_PATH/openapi-generator-cli" && \
#    # Make runnable for gitpod user
#    echo "export PATH=$PATH:$OPENAPI_PATH/" >> /home/gitpod/.bashrc && \
#    echo "export OPENAPI_GENERATOR_VERSION=$OPENAPI_GENERATOR_VERSION" >> /home/gitpod/.bashrc
# Downloads maven deps as side effect
#RUN $OPENAPI_PATH/openapi-generator-cli version

### Prologue (built across all layers) ###
LABEL dazzle/layer=dazzle-prologue
LABEL dazzle/test=tests/prologue.yaml

USER root
RUN curl -o /usr/bin/dazzle-util -L https://github.com/32leaves/dazzle/releases/download/v0.0.3/dazzle-util_0.0.3_Linux_x86_64 \
    && chmod +x /usr/bin/dazzle-util
# merge dpkg status files
RUN cp /var/lib/dpkg/status /tmp/dpkg-status \
    && for i in $(ls /var/lib/apt/dazzle-marks/*.status); do /usr/bin/dazzle-util debian dpkg-status-merge /tmp/dpkg-status $i > /tmp/dpkg-status; done \
    && cp -f /var/lib/dpkg/status /var/lib/dpkg/status-old \
    && cp -f /tmp/dpkg-status /var/lib/dpkg/status
# copy tests to enable the self-test of this image
COPY tests /var/lib/dazzle/tests

USER gitpod
