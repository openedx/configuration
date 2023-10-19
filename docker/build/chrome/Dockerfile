FROM selenium/standalone-chrome-debug:4.1.2-20220217
LABEL maintainer="edxops"

USER root

# Install a password generator
RUN apt-get update -qqy \
  && apt-get -qqy install \
  pwgen \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

USER seluser

CMD export VNC_PASSWORD=$(pwgen -s -1 $(shuf -i 10-20 -n 1)) \
  && x11vnc -storepasswd $VNC_PASSWORD /home/seluser/.vnc/passwd \
  && echo "Chrome VNC password: $VNC_PASSWORD" \
  && /opt/bin/entry_point.sh

EXPOSE 4444 5900
