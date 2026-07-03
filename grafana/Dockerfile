FROM grafana/grafana:13.0.1-security-01

USER root

COPY grafana/custom/custom.css /usr/share/grafana/public/custom.css
RUN sed -i 's|</head>|<!-- mime-monitoring-custom-css --><link rel="stylesheet" href="public/custom.css" /></head>|' /usr/share/grafana/public/views/index.html

USER 472
