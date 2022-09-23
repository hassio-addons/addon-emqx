#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: EMQX
# Configures EMQX
# ==============================================================================
mkdir -p \
  /data/emqx/data \
  /data/emqx/etc \
  /data/emqx/log \
  /data/emqx/plugins

ln -s /data/emqx/log /opt/emqx/log
