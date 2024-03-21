# To build this Dockerfile:
#
# From the root of configuration:
#
# docker build -f docker/build/edxapp/Dockerfile .
#
# This allows the dockerfile to update /edx/app/edx_ansible/edx_ansible
# with the currently checked-out configuration repo.

ARG BASE_IMAGE_TAG=ironwood.master
FROM edxops/xenial-common:${BASE_IMAGE_TAG}
MAINTAINER edxops
USER root
CMD ["/edx/app/supervisor/venvs/supervisor/bin/supervisord", "-n", "--configuration", "/edx/app/supervisor/supervisord.conf"]

ADD . /edx/app/edx_ansible/edx_ansible
WORKDIR /edx/app/edx_ansible/edx_ansible/docker/plays

COPY docker/build/edxapp/ansible_overrides.yml /
COPY docker/build/edxapp/devstack.yml /
COPY docker/devstack_common_ansible_overrides.yml /devstack/ansible_overrides.yml

ARG OPENEDX_RELEASE=open-release/ironwood.master
ENV OPENEDX_RELEASE=${OPENEDX_RELEASE}
RUN sudo apt update
RUN sudo /edx/app/edx_ansible/venvs/edx_ansible/bin/ansible-playbook -vvv edxapp.yml \
    -c local -i '127.0.0.1,' \
    -t 'install,assets,devstack' \
    --extra-vars="edx_platform_version=${OPENEDX_RELEASE}" \
    --extra-vars="@/ansible_overrides.yml" \
    --extra-vars="@/devstack.yml" \
    --extra-vars="@/devstack/ansible_overrides.yml" \
    && rm -rf /edx/app/edxapp/edx-platform

EXPOSE 18000 18010
