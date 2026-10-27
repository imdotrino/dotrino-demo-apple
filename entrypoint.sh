#!/usr/bin/env bash
# La demo de Terminal para la revisión de Apple. Dos órdenes:
#
#   prepare    UNA vez, con -it: crea la bóveda, el login del revisor (la contraseña se
#              teclea aquí) y la máquina, y guarda la COPIA en /data/snapshot.
#   serve      cada arranque: restaura la copia en /data/run y corre bóveda + máquina.
#              Todo lo que el revisor cambie se pierde en el siguiente arranque.
#
# Corre como root solo para preparar el contenedor; la bóveda corre como `vault` y la
# máquina (y las shells del revisor) como `tester`.
set -euo pipefail

DATA=/data
RUN=$DATA/run
SNAPSHOT=$DATA/snapshot
PROXY=${DEMO_PROXY:-wss://proxy.dotrino.com}
REVIEWER=${DEMO_USER:-apple}
MACHINE=${DEMO_MACHINE_NAME:-Máquina de prueba}

say () { echo "[demo] $*"; }
die () { echo "[demo] $*" >&2; exit 1; }

# El entorno de la bóveda, en UN sitio: lo usan as_vault y el `script` de reset_reviewer_password.
VAULT_ENV=(PATH="$PATH" HOME="$RUN/vault" LANG=C.UTF-8
  DOTRINO_VAULT_DIR="$RUN/vault" XDG_RUNTIME_DIR=/run/vault PROXY_URL="$PROXY")

as_vault () {
  setpriv --reuid=vault --regid=vault --init-groups env -i "${VAULT_ENV[@]}" "$@"
}
as_tester () {
  setpriv --reuid=tester --regid=tester --init-groups \
    env -i PATH="$PATH" HOME="$RUN/home" LANG=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash "$@"
}

# El machine-id vive en el volumen: es de lo que sale la clave con la que la bóveda cifra
# su disco, y tiene que ser el mismo en cada contenedor o la copia no abre
# (`kek-machine-changed`). La bóveda lee las dos rutas.
machine_id () {
  [ -s "$DATA/machine-id" ] || die "missing $DATA/machine-id: run 'prepare' first"
  install -m 0444 "$DATA/machine-id" /etc/machine-id
  mkdir -p /var/lib/dbus && install -m 0444 "$DATA/machine-id" /var/lib/dbus/machine-id
}

# /data se puede ATRAVESAR pero no listar: `vault` y `tester` llegan a sus carpetas de
# /data/run, y nadie más que root ve el machine-id, la dirección o la copia. No se fía de cómo
# se creó el volumen (un directorio 0700 del host dejaba a la bóveda sin poder arrancar).
fix_data_perms () {
  chmod 0711 "$DATA"
  for f in machine-id address prepare.log; do [ -e "$DATA/$f" ] && chmod 0600 "$DATA/$f"; done
  [ -e "$SNAPSHOT" ] && chmod 0700 "$SNAPSHOT"
  return 0
}

# Lo que el revisor puede ensuciar fuera de /data/run, limpio en cada arranque.
clean_temp () {
  find /tmp /var/tmp /dev/shm -mindepth 1 -delete 2>/dev/null || true
  install -d -o vault -g vault -m 0700 /run/vault
}

# Solo deja salir hacia el proxio. Pedido y no aplicable = no se arranca: una demo con una
# shell abierta a internet es justo lo que esto evita.
firewall () {
  [ "${DEMO_FIREWALL:-0}" = 1 ] || { say "firewall off (DEMO_FIREWALL=1 to restrict egress to the proxy)"; return; }
  local host ips
  host=$(echo "$PROXY" | sed -E 's#^wss?://([^/:]+).*#\1#')
  ips=$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u)
  [ -n "$ips" ] || die "firewall: could not resolve $host"
  iptables -F OUTPUT || die "firewall: iptables failed (needs NET_ADMIN)"
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  for ip in $ips; do iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT; done
  # El DNS, solo hacia los resolvers del contenedor: el proxio se resuelve al conectar. En
  # Fly el resolver es IPv6 (fdaa::3), así que hacen falta las dos familias.
  for ns in $(awk '/^nameserver/ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf); do
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
  done
  iptables -P OUTPUT DROP
  ip6tables -F OUTPUT || die "firewall: ip6tables failed"
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  for ns in $(awk '/^nameserver/ && $2 ~ /:/ {print $2}' /etc/resolv.conf); do
    ip6tables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    ip6tables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
  done
  # El descubrimiento de vecinos de IPv6 va por ICMPv6. Sin él la máquina deja de contestar
  # por IPv6 en cuanto caduca su caché de vecinos: en Fly, el SSH (que entra por la red
  # privada IPv6) se colgaba unos minutos después de arrancar. Solo esos tipos, más
  # «paquete demasiado grande», que hace falta para que TCP no se atasque.
  for t in neighbour-solicitation neighbour-advertisement router-solicitation packet-too-big; do
    ip6tables -A OUTPUT -p icmpv6 --icmpv6-type "$t" -j ACCEPT
  done
  ip6tables -P OUTPUT DROP
  say "firewall on: egress only to $host ($(echo $ips | tr '\n' ' '))"
}

wait_for_vault () {
  for _ in $(seq 1 100); do
    as_vault dotrino-vault status >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  die "the vault did not start"
}

prepare () {
  [ -t 0 ] || die "prepare needs a terminal to type the password: docker run -it …"
  [ ! -e "$SNAPSHOT" ] || die "$SNAPSHOT already exists: delete the volume to prepare again (the address changes)"
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$DATA/machine-id"; echo >> "$DATA/machine-id"
  fix_data_perms
  machine_id
  clean_temp
  rm -rf "$RUN"
  install -d -m 0755 "$RUN"
  install -d -o vault -g vault -m 0700 "$RUN/vault"
  install -d -o tester -g tester -m 0700 "$RUN/machine" "$RUN/home"

  say "starting the vault"
  as_vault dotrino-vaultd >"$DATA/prepare.log" 2>&1 &
  local vpid=$!
  wait_for_vault

  say "login for the reviewer: $REVIEWER (type the password twice, 12+ characters)"
  as_vault dotrino-vault logins add "$REVIEWER" "App Review"

  say "linking the machine: $MACHINE"
  local inv code_file=/tmp/demo-code
  inv=$(as_vault dotrino-vault pair --quiet --name "$MACHINE")
  as_tester node /opt/demo/link.mjs "$inv" "$RUN/machine" "$code_file" &
  local epid=$!
  for _ in $(seq 1 150); do [ -s "$code_file" ] && break; sleep 0.2; done
  [ -s "$code_file" ] || die "the machine never asked to be approved"
  as_vault dotrino-vault approve "$(cat "$code_file")"
  wait "$epid" || die "linking the machine failed"

  local address
  address=$(as_vault dotrino-vault logins | grep -o "$REVIEWER@[0-9A-F-]*" | head -1)
  kill -TERM "$vpid"; wait "$vpid" || true

  cp -a "$RUN" "$SNAPSHOT"
  # La copia es SOLO de root (`fix_data_perms`): dentro hay carpetas de `tester` (su home, el
  # enlace de la máquina) y, si llegara a ellas, plantaría algo que sobreviviría a cada reset.
  echo "$address" > "$DATA/address"
  fix_data_perms
  say "ready. Sign-in information for App Store Connect:"
  say "  user:     $address"
  say "  password: the one you just typed"
}

# La copia como UNA línea de texto (tar.gz en base64): para plataformas sin disco persistente
# (Timone), donde llega por la variable DEMO_SNAPSHOT_B64. Lleva la bóveda de la demo: quien la
# tenga controla esa cuenta, así que va a una variable que solo ve el dueño, nunca a la imagen
# ni a un repo.
export_snapshot () {
  [ -d "$SNAPSHOT" ] || die "no copy in $SNAPSHOT to export"
  # `export 8000` la parte en líneas de 8000: una por variable DEMO_SNAPSHOT_B64_<n>.
  if [ -n "${2:-}" ]; then tar -C "$DATA" -czf - snapshot machine-id address | base64 -w "$2"
  else tar -C "$DATA" -czf - snapshot machine-id address | base64 -w0; fi
  echo
}

# Lee la variable $1, o sus trozos $1_1, $1_2…, y deja el texto en $b64 y el número de
# trozos en $parts (las dos son `local` de quien llama).
read_snapshot_vars () {
  local prefix=$1 var
  b64=${!prefix:-} parts=0
  while var="${prefix}_$((parts + 1))"; [ -n "${!var:-}" ]; do b64+=${!var}; parts=$((parts + 1)); done
}

import_from_env () {
  # Una variable, o en trozos DEMO_SNAPSHOT_B64_1, _2… (Timone limita cada valor a 8192
  # caracteres y la copia no baja de ~56 000: la identidad va cifrada y no se comprime).
  local b64 parts name=DEMO_SNAPSHOT_B64
  read_snapshot_vars "$name"
  [ -n "$b64" ] || return 0
  rm -rf "$SNAPSHOT"
  install -d -m 0711 "$DATA"
  echo "$b64" | base64 -d | tar -C "$DATA" -xzpf - || die "$name is not a snapshot made by 'export'"
  say "snapshot loaded from $name ($parts parts)"
}

# LA CONTRASEÑA DEL REVISOR, por variable. La que se tecleó al preparar vive solo en la copia
# (nadie más la tiene: la bóveda no la guarda en claro) y `logins passwd` pide la actual. Con
# DEMO_PASSWORD, cada arranque quita el usuario y lo vuelve a crear con esa contraseña: la
# dirección es la misma (sale del perfil) y lo único que cambia es el ID de su aparato. Va a una
# variable que solo ve el dueño, nunca al repo ni a la imagen.
reset_reviewer_password () {
  [ -n "${DEMO_PASSWORD:-}" ] || return 0
  [ "${#DEMO_PASSWORD}" -ge 12 ] || die "reviewer password: DEMO_PASSWORD needs 12 characters or more"
  local vault_env="env -i ${VAULT_ENV[*]}"
  retry as_vault dotrino-vault logins rm "$REVIEWER" || die "reviewer password: could not remove the old login"
  # `logins add` lee la contraseña de una terminal: `script` le da una, y aquí se le teclea.
  (sleep 2; echo "$DEMO_PASSWORD"; sleep 1; echo "$DEMO_PASSWORD"; sleep 4) \
    | script -qec "setpriv --reuid=vault --regid=vault --init-groups $vault_env dotrino-vault logins add '$REVIEWER' 'App Review' +approve" /dev/null >/dev/null 2>&1
  as_vault dotrino-vault logins | grep -q "$REVIEWER@" || die "reviewer password: the login was not created"
  say "reviewer login reset from DEMO_PASSWORD (same address)"
}

# LOS PEDIDOS DE MUESTRA, para la revisión de la app Dotrino (la pestaña Pedidos): el revisor
# entra con el mismo usuario y tiene que ver algo que aprobar. En cada arranque, sobre la copia
# recién restaurada: el usuario del revisor recibe el permiso de aprobar, y se enlaza un servicio
# («Servidor de prueba») que pide las claves de su cajón cada DEMO_REQUEST_SECONDS. No toca la
# copia: la dirección y la contraseña siguen siendo las mismas, y un reset lo rehace.
SERVICE=demo
sample_requests () {
  local id inv sid code=/tmp/demo-service-code out=/tmp/demo-service-enroll
  id=$(as_vault dotrino-vault logins | sed 's/\x1b\[[0-9;]*m//g' | awk -v u="$REVIEWER@" 'index($0, u) {print $3; exit}')
  [ -n "$id" ] || die "sample requests: login $REVIEWER not found"
  retry as_vault dotrino-vault caps "$id" +approve || die "sample requests: could not grant approve to $id"
  retry as_vault dotrino-vault secret set "$SERVICE" API_KEY "clave-de-muestra" || die "sample requests: could not store the sample key"
  inv=$(as_vault dotrino-vault pair --quiet --service "$SERVICE" --name "Servidor de prueba") \
    || die "sample requests: could not create the invitation"
  # Corre con el usuario de la bóveda: solo así alcanza su mostrador local, que es por donde
  # el pedido lleva el comando (por el proxio va sin él y el teléfono decía «no dice qué está
  # ejecutando»). No es del revisor: es un proceso de la demo.
  install -d -o vault -g vault -m 0700 "$RUN/service"
  as_vault env DOTRINO_ENV_HOME="$RUN/service" \
    dotrino-env enroll --ns "$SERVICE" --code "$inv" >"$out" 2>&1 &
  local epid=$!
  # El servicio enseña un código y un ID; la bóveda lo aprueba (como con la máquina).
  for _ in $(seq 1 150); do grep -q 'dotrino-vault approve' "$out" 2>/dev/null && break; sleep 0.2; done
  code=$(sed 's/\x1b\[[0-9;]*m//g' "$out" | awk '/dotrino-vault approve/ {print $3; exit}')
  sid=$(sed 's/\x1b\[[0-9;]*m//g' "$out" | awk '/Dispositivo:/ {print $2; exit}')
  [ -n "$code" ] && [ -n "$sid" ] || die "sample requests: the sample service never asked to be approved"
  as_vault dotrino-vault approve "$code" >/dev/null || die "sample requests: could not approve the sample service"
  wait "$epid" || die "sample requests: the sample service could not enroll"
  # Pedir aprobación es el defecto de la bóveda: el servicio no recibe sus claves hasta que un
  # aparato con «aprueba» dice que sí. No hay nada más que marcar.
  rm -f "$out"
  say "sample requests on: $REVIEWER ($id) can approve; $sid asks every ${DEMO_REQUEST_SECONDS:-180}s"
}

# La bóveda aplica un cambio del acta cada vez: el siguiente, pegado, puede llegar antes de que
# termine. Se reintenta unos segundos y, si sigue sin entrar, se dice.
retry () {
  for _ in 1 2 3 4 5 6; do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  "$@" >/dev/null
}

# Un pedido cada vez, con un comando distinto (la bóveda recuerda una hora el comando aprobado:
# repetirlo no volvería a preguntar). El que nadie contesta vence solo.
request_loop () {
  local n=0
  cd /opt/demo
  while true; do
    n=$((n + 1))
    as_vault env DOTRINO_ENV_HOME="$RUN/service" DOTRINO_ENV_QUIET=1 \
      timeout "${DEMO_REQUEST_SECONDS:-180}" dotrino-env run --ns "$SERVICE" -- /bin/echo "Dotrino demo: sample deploy $n" >/dev/null 2>&1 || true
    sleep 5
  done
}

# Un 200 en un puerto, para la plataforma que exige uno (Timone). No sirve nada de la demo.
http_port () {
  [ -n "${DEMO_HTTP_PORT:-}" ] || return 0
  setpriv --reuid=nobody --regid=nogroup --clear-groups env -i PATH="$PATH" \
    node -e "require('http').createServer((q, r) => r.end('ok\\n')).listen(+process.argv[1])" "$DEMO_HTTP_PORT" &
  HTTP_PID=$!
}

serve () {
  import_from_env
  if [ ! -d "$SNAPSHOT" ]; then
    # Sin copia no hay nada que servir. Se espera en vez de salir: en Fly la preparación se
    # hace DENTRO de esta máquina (fly ssh console), y salir la metería en un bucle de reinicios.
    say "no copy in $SNAPSHOT: nothing to serve. Prepare it inside this container, then restart it:"
    say "  docker exec -it <container> /opt/demo/entrypoint.sh prepare"
    say "  fly ssh console -C '/opt/demo/entrypoint.sh prepare'"
    exec sleep infinity
  fi
  fix_data_perms
  machine_id
  clean_temp
  firewall
  rm -rf "$RUN"
  cp -a "$SNAPSHOT" "$RUN"
  chmod 0755 "$RUN"   # `cp -a` le pasa el 0700 de la copia; dentro, cada carpeta tiene el suyo
  # Estado de ejecución que no debe venir de la copia: el pid de otro contenedor puede
  # coincidir con un proceso de este y hacer creer que ya corre otra bóveda u otro agente.
  rm -f "$RUN/vault/vault.lock" "$RUN/vault/state.json" "$RUN/machine/agent.pid"

  say "serving $(cat "$DATA/address" 2>/dev/null) through $PROXY"
  as_vault dotrino-vaultd &
  local vpid=$!
  wait_for_vault
  as_tester dotrino-terminal-agent --dir "$RUN/machine" --proxy "$PROXY" --shell /bin/bash &
  local apid=$!
  HTTP_PID=
  http_port
  if ! ( reset_reviewer_password ); then say "the reviewer password was NOT reset (the error is above); the old one still applies"; fi
  # Apagable con DEMO_REQUESTS=0 (la demo queda como estaba: solo la terminal).
  local ppid=
  # En un subshell: si no se pueden montar, se dice y la terminal de la demo sigue sirviendo
  # (un `die` aquí metería el contenedor en un bucle de reinicios y tumbaría las dos demos).
  if [ "${DEMO_REQUESTS:-1}" = 1 ]; then
    if ( sample_requests ); then request_loop & ppid=$!
    else say "sample requests are OFF (the error is above); the terminal demo keeps running"; fi
  fi

  # Reset periódico: salir y que la política de reinicio (docker --restart, Fly) lo levante
  # desde la copia.
  local rpid=
  if [ -n "${DEMO_RESET_SECONDS:-}" ]; then sleep "$DEMO_RESET_SECONDS" & rpid=$!; fi

  trap 'kill -TERM $vpid $apid ${rpid:-} ${HTTP_PID:-} ${ppid:-} 2>/dev/null || true' TERM INT
  set +e
  wait -n $vpid $apid ${rpid:-} ${HTTP_PID:-}
  local code=$?
  kill -TERM $vpid $apid ${rpid:-} ${HTTP_PID:-} ${ppid:-} 2>/dev/null
  wait
  say "stopped (exit $code)"
  exit $code
}

# Con quién corremos: sin root no hay dos usuarios, y sin NET_ADMIN no hay firewall. En una
# plataforma que no lo documenta (Timone) es lo primero que hay que saber, y sale en el log.
say "running as uid $(id -u), effective capabilities $(awk '/^CapEff/ {print $2}' /proc/self/status)" >&2

case "${1:-serve}" in
  prepare) prepare ;;
  export) export_snapshot "$@" ;;
  serve) serve ;;
  *) die "usage: prepare | serve | export" ;;
esac
