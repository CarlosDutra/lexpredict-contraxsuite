#!/bin/bash

set -e

IMAGE_UUID_FILE=/build.uuid
DEPLOYMENT_UUID_FILE=/deployment_uuid/deployment.uuid

echo ""
echo ===================================================================
cat /build.info
echo "Build UUID:"
cat ${IMAGE_UUID_FILE}
if [ -e ${DEPLOYMENT_UUID_FILE} ]; then
    echo "Deployment UUID: $(cat ${DEPLOYMENT_UUID_FILE})"
else
    echo "Deployment UUID not stored yet"
fi
echo "Going to start: $1..."
echo ===================================================================
echo ""

echo "Adding Docker <-> Host shared user..."
if ! adduser -u ${SHARED_USER_ID} --disabled-password --gecos "" ${SHARED_USER_NAME} ; then
    echo "Shared user already exists: ${SHARED_USER_NAME} (${SHARED_USER_ID})"
fi

echo "Adding Docker Shared User to root group..."
usermod -a -G root ${SHARED_USER_NAME}


echo "Creating data dirs..."
mkdir -p /data/data
mkdir -p /data/logs
mkdir -p /data/media/data/documents
mkdir -p $(dirname ${DEPLOYMENT_UUID_FILE})

echo "Configuring permissions..."
chown -v ${SHARED_USER_NAME}:${SHARED_USER_NAME} /contraxsuite_services || true
chown -R -v ${SHARED_USER_NAME}:${SHARED_USER_NAME} /contraxsuite_services/staticfiles || true
chown -R -v ${SHARED_USER_NAME}:${SHARED_USER_NAME} /data || true
chown -R -v ${SHARED_USER_NAME}:${SHARED_USER_NAME} /static || true
chmod -R -v ug+rw /data/media/data/documents || true


echo "Preparing configuration based on env variables..."
pushd /config-templates

export DOLLAR='$' # escape $ in envsubst

if [ -z "${DOCKER_NGINX_CERTIFICATE}" ]; then
    echo "Embedded Nginx is going to serve plain HTTP."
    envsubst < nginx-http.conf.template > /etc/nginx/conf.d/default.conf
else
    echo "Embedded Nginx is going to serve HTTPS."
    envsubst < nginx-https.conf.template > /etc/nginx/conf.d/default.conf
fi

envsubst < nginx.conf.template > /etc/nginx/nginx.conf
envsubst < nginx-internal.conf.template > /etc/nginx/conf.d/internal.conf
envsubst < run-celery.sh.template > /contraxsuite_services/run-celery.sh
envsubst < run-uwsgi.sh.template > /contraxsuite_services/run-uwsgi.sh
envsubst < local_settings.py.template > /contraxsuite_services/local_settings.py

chmod ug+x /contraxsuite_services/run-celery.sh
chmod ug+x /contraxsuite_services/run-uwsgi.sh

popd


echo "Preparing NLTK data..."
chown -R ${SHARED_USER_NAME}:${SHARED_USER_NAME} /root/nltk_data
mv /root/nltk_data /home/${SHARED_USER_NAME}/
echo =======NLTK======
ls -lL /home/${SHARED_USER_NAME}/nltk_data
echo =================

pushd /contraxsuite_services

if [ $1 == "uwsgi" ]; then
    if ! cmp --silent ${IMAGE_UUID_FILE} ${DEPLOYMENT_UUID_FILE} ; then
        echo "Preparing theme..."
        THEME_ZIP=/third_party_dependencies/$(basename ${DOCKER_DJANGO_THEME_ARCHIVE})
        THEME_DIR=/static/theme
        mkdir -p ${THEME_DIR}
        unzip ${THEME_ZIP} "Package-HTML/HTML/js/*" -d ${THEME_DIR}
        unzip ${THEME_ZIP} "Package-HTML/HTML/css/*" -d ${THEME_DIR}
        unzip ${THEME_ZIP} "Package-HTML/HTML/images/*" -d ${THEME_DIR}
        unzip ${THEME_ZIP} "Package-HTML/HTML/style.css" -d ${THEME_DIR}
        mv ${THEME_DIR}/Package-HTML/HTML/js ${THEME_DIR}/
        mv ${THEME_DIR}/Package-HTML/HTML/css ${THEME_DIR}/
        mv ${THEME_DIR}/Package-HTML/HTML/images ${THEME_DIR}/
        mv ${THEME_DIR}/Package-HTML/HTML/style.css ${THEME_DIR}/css/

        echo "Preparing jqwidgets..."
        JQWIDGETS_ZIP=/third_party_dependencies/$(basename ${DOCKER_DJANGO_JQWIDGETS_ARCHIVE})
        VENDOR_DIR=/static/vendor
        unzip ${JQWIDGETS_ZIP} "jqwidgets/*" -d ${VENDOR_DIR}



        echo "Collecting DJANGO static files..."
        su - ${SHARED_USER_NAME} -c "export LANG=C.UTF-8 && cd /contraxsuite_services && \
            . /contraxsuite_services/venv/bin/activate && \
            python manage.py collectstatic --noinput"

        popd

        cat /build.info > /contraxsuite_services/staticfiles/version.txt
        echo "" >> /contraxsuite_services/staticfiles/version.txt
        cat /build.uuid >> /contraxsuite_services/staticfiles/version.txt
    fi

    # Put this build uuid to a persistent storage to avoid running preparation procedures again
    # (see start of this script)
    cat ${IMAGE_UUID_FILE} > ${DEPLOYMENT_UUID_FILE}

    echo "Sleeping 5 seconds to let Postgres start"
    sleep 5

    while ! curl http://${DOCKER_HOST_NAME_PG}:5432/ 2>&1 | grep '52'
    do
      echo "Sleeping 5 seconds to let Postgres start"
      sleep 5
    done

    echo "Ensuring Django superuser is created..."

# Indentation makes sense here
su - ${SHARED_USER_NAME} -c "export LANG=C.UTF-8 && cd /contraxsuite_services && \
    . /contraxsuite_services/venv/bin/activate && \
    python manage.py force_migrate && \
    python manage.py shell -c \"
from apps.users.models import User
if not User.objects.filter(username = '${DOCKER_DJANGO_ADMIN_NAME}').exists():
    User.objects.create_superuser('${DOCKER_DJANGO_ADMIN_NAME}', '${DOCKER_DJANGO_ADMIN_EMAIL}', '${DOCKER_DJANGO_ADMIN_PASSWORD}', role='technical_admin')
\""

    if [ $2 == "shell" ]; then
        /bin/bash
    else
        echo "Starting Nginx and Django..."
        service nginx start && \
        su - ${SHARED_USER_NAME} -c "export LANG=C.UTF-8 && cd /contraxsuite_services && \
            . /contraxsuite_services/venv/bin/activate && \
            uwsgi --socket 0.0.0.0:3031 \
                    --plugins python3 \
                    --protocol uwsgi \
                    --wsgi wsgi:application" && \
        service nginx stop
    fi
else
    echo "Sleeping 15 seconds to let Postgres start and Django migrate"
    sleep 15
    echo "Starting Celery..."

    su - ${SHARED_USER_NAME} -c "export LANG=C.UTF-8 && cd /contraxsuite_services && . /contraxsuite_services/venv/bin/activate && \
        celery worker -A apps --concurrency=4 -B"
fi
