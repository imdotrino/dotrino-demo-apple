#!/usr/bin/env bash
# La demo de Terminal para la revisión de Apple. Dos órdenes:
#
#   preparar   UNA vez, con -it: crea la bóveda, el login del revisor (la contraseña se
#              teclea aquí) y la máquina, y guarda la COPIA en /data/copia.
#   servir     cada arranque: restaura la copia en /data/run y corre bóveda + máquina.
#              Todo lo que el revisor cambie se pierde en el siguiente arranque.
#
# Corre como root solo para preparar el contenedor; la bóveda corre como `vault` y la
# máquina (y las shells del revisor) como `tester`.
set -euo pipefail

DATA=/data
RUN=$DATA/run
COPIA=$DATA/copia
PROXY=${DEMO_PROXY:-wss://proxy.dotrino.com}
USUARIO=${DEMO_USER:-apple}
MAQUINA=${DEMO_MACHINE_NAME:-Máquina de prueba}

say () { echo "[demo] $*"; }
die () { echo "[demo] $*" >&2; exit 1; }

as_vault () {
  setpriv --reuid=vault --regid=vault --init-groups \
    env -i PATH="$PATH" HOME="$RUN/vault" LANG=C.UTF-8 \
      DOTRINO_VAULT_DIR="$RUN/vault" XDG_RUNTIME_DIR=/run/vault PROXY_URL="$PROXY" "$@"
}
as_tester () {
  setpriv --reuid=tester --regid=tester --init-groups \
    env -i PATH="$PATH" HOME="$RUN/home" LANG=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash "$@"
}

# El machine-id vive en el volumen: es de lo que sale la clave con la que la bóveda cifra
# su disco, y tiene que ser el mismo en cada contenedor o la copia no abre
# (`kek-machine-changed`). La bóveda lee las dos rutas.
machine_id () {
  [ -s "$DATA/machine-id" ] || die "missing $DATA/machine-id: run 'preparar' first"
  install -m 0444 "$DATA/machine-id" /etc/machine-id
  mkdir -p /var/lib/dbus && install -m 0444 "$DATA/machine-id" /var/lib/dbus/machine-id
}

# /data se puede ATRAVESAR pero no listar: `vault` y `tester` llegan a sus carpetas de
# /data/run, y nadie más que root ve el machine-id, la dirección o la copia. No se fía de cómo
# se creó el volumen (un directorio 0700 del host dejaba a la bóveda sin poder arrancar).
permisos_data () {
  chmod 0711 "$DATA"
  for f in machine-id address preparar.log; do [ -e "$DATA/$f" ] && chmod 0600 "$DATA/$f"; done
  [ -e "$COPIA" ] && chmod 0700 "$COPIA"
  return 0
}

# Lo que el revisor puede ensuciar fuera de /data/run, limpio en cada arranque.
limpiar_temporales () {
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

esperar_boveda () {
  for _ in $(seq 1 100); do
    as_vault dotrino-vault status >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  die "the vault did not start"
}

preparar () {
  [ -t 0 ] || die "preparar needs a terminal to type the password: docker run -it …"
  [ ! -e "$COPIA" ] || die "$COPIA already exists: delete the volume to prepare again (the address changes)"
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$DATA/machine-id"; echo >> "$DATA/machine-id"
  permisos_data
  machine_id
  limpiar_temporales
  rm -rf "$RUN"
  install -d -m 0755 "$RUN"
  install -d -o vault -g vault -m 0700 "$RUN/vault"
  install -d -o tester -g tester -m 0700 "$RUN/maquina" "$RUN/home"

  say "starting the vault"
  as_vault dotrino-vaultd >"$DATA/preparar.log" 2>&1 &
  local vpid=$!
  esperar_boveda

  say "login for the reviewer: $USUARIO (type the password twice, 12+ characters)"
  as_vault dotrino-vault logins add "$USUARIO" "App Review"

  say "linking the machine: $MAQUINA"
  local inv codigo=/tmp/demo-code
  inv=$(as_vault dotrino-vault pair --quiet --name "$MAQUINA")
  as_tester node /opt/demo/enlazar.mjs "$inv" "$RUN/maquina" "$codigo" &
  local epid=$!
  for _ in $(seq 1 150); do [ -s "$codigo" ] && break; sleep 0.2; done
  [ -s "$codigo" ] || die "the machine never asked to be approved"
  as_vault dotrino-vault approve "$(cat "$codigo")"
  wait "$epid" || die "linking the machine failed"

  local direccion
  direccion=$(as_vault dotrino-vault logins | grep -o "$USUARIO@[0-9A-F-]*" | head -1)
  kill -TERM "$vpid"; wait "$vpid" || true

  cp -a "$RUN" "$COPIA"
  # La copia es SOLO de root (`permisos_data`): dentro hay carpetas de `tester` (su home, el
  # enlace de la máquina) y, si llegara a ellas, plantaría algo que sobreviviría a cada reset.
  echo "$direccion" > "$DATA/address"
  permisos_data
  say "ready. Sign-in information for App Store Connect:"
  say "  user:     $direccion"
  say "  password: the one you just typed"
}

# La copia como UNA línea de texto (tar.gz en base64): para plataformas sin disco persistente
# (Timone), donde llega por la variable DEMO_COPIA_B64. Lleva la bóveda de la demo: quien la
# tenga controla esa cuenta, así que va a una variable que solo ve el dueño, nunca a la imagen
# ni a un repo.
exportar () {
  [ -d "$COPIA" ] || die "no copy in $COPIA to export"
  # `exportar 8000` la parte en líneas de 8000: una por variable DEMO_COPIA_B64_<n>.
  if [ -n "${2:-}" ]; then tar -C "$DATA" -czf - copia machine-id address | base64 -w "$2"
  else tar -C "$DATA" -czf - copia machine-id address | base64 -w0; fi
  echo
}

importar_de_variable () {
  # Una variable, o en trozos DEMO_COPIA_B64_1, _2… (Timone limita cada valor a 8192
  # caracteres y la copia no baja de ~56 000: la identidad va cifrada y no se comprime).
  local b64=${DEMO_COPIA_B64:-} n=1 var
  while var="DEMO_COPIA_B64_$n"; [ -n "${!var:-}" ]; do b64+=${!var}; n=$((n + 1)); done
  [ -n "$b64" ] || return 0
  rm -rf "$COPIA"
  install -d -m 0711 "$DATA"
  echo "$b64" | base64 -d | tar -C "$DATA" -xzpf - || die "DEMO_COPIA_B64 is not a copy made by 'exportar'"
  say "copy loaded from DEMO_COPIA_B64 ($(( n - 1 )) parts)"
}

# LOS PEDIDOS DE MUESTRA, para la revisión de la app Dotrino (la pestaña Pedidos): el revisor
# entra con el mismo usuario y tiene que ver algo que aprobar. En cada arranque, sobre la copia
# recién restaurada: el usuario del revisor recibe el permiso de aprobar, y se enlaza un servicio
# («Servidor de prueba») que pide las claves de su cajón cada DEMO_REQUEST_SECONDS. No toca la
# copia: la dirección y la contraseña siguen siendo las mismas, y un reset lo rehace.
SERVICIO=demo
pedidos_de_muestra () {
  local id inv sid codigo=/tmp/demo-service-code out=/tmp/demo-service-enroll
  id=$(as_vault dotrino-vault logins | sed 's/\x1b\[[0-9;]*m//g' | awk -v u="$USUARIO@" 'index($0, u) {print $3; exit}')
  [ -n "$id" ] || die "sample requests: login $USUARIO not found"
  reintentar as_vault dotrino-vault caps "$id" +aprueba || die "sample requests: could not grant approve to $id"
  reintentar as_vault dotrino-vault secret set "$SERVICIO" API_KEY "clave-de-muestra" || die "sample requests: could not store the sample key"
  inv=$(as_vault dotrino-vault pair --quiet --service "$SERVICIO" --name "Servidor de prueba") \
    || die "sample requests: could not create the invitation"
  install -d -o tester -g tester -m 0700 "$RUN/servicio"
  as_tester env DOTRINO_ENV_HOME="$RUN/servicio" \
    dotrino-env enroll --ns "$SERVICIO" --code "$inv" >"$out" 2>&1 &
  local epid=$!
  # El servicio enseña un código y un ID; la bóveda lo aprueba (como con la máquina).
  for _ in $(seq 1 150); do grep -q 'dotrino-vault approve' "$out" 2>/dev/null && break; sleep 0.2; done
  codigo=$(sed 's/\x1b\[[0-9;]*m//g' "$out" | awk '/dotrino-vault approve/ {print $3; exit}')
  sid=$(sed 's/\x1b\[[0-9;]*m//g' "$out" | awk '/Dispositivo:/ {print $2; exit}')
  [ -n "$codigo" ] && [ -n "$sid" ] || die "sample requests: the sample service never asked to be approved"
  as_vault dotrino-vault approve "$codigo" >/dev/null || die "sample requests: could not approve the sample service"
  wait "$epid" || die "sample requests: the sample service could not enroll"
  # Pedir aprobación es el defecto de la bóveda: el servicio no recibe sus claves hasta que un
  # aparato con «aprueba» dice que sí. No hay nada más que marcar.
  rm -f "$out"
  say "sample requests on: $USUARIO ($id) can approve; $sid asks every ${DEMO_REQUEST_SECONDS:-180}s"
}

# La bóveda aplica un cambio del acta cada vez: el siguiente, pegado, puede llegar antes de que
# termine. Se reintenta unos segundos y, si sigue sin entrar, se dice.
reintentar () {
  for _ in 1 2 3 4 5 6; do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  "$@" >/dev/null
}

# Un pedido cada vez, con un comando distinto (la bóveda recuerda una hora el comando aprobado:
# repetirlo no volvería a preguntar). El que nadie contesta vence solo.
bucle_de_pedidos () {
  local n=0
  cd "$RUN/home"
  while true; do
    n=$((n + 1))
    as_tester env DOTRINO_ENV_HOME="$RUN/servicio" DOTRINO_ENV_QUIET=1 \
      timeout "${DEMO_REQUEST_SECONDS:-180}" dotrino-env run --ns "$SERVICIO" -- /bin/echo "deploy $n" >/dev/null 2>&1 || true
    sleep 5
  done
}

# Un 200 en un puerto, para la plataforma que exige uno (Timone). No sirve nada de la demo.
puerto_http () {
  [ -n "${DEMO_HTTP_PORT:-}" ] || return 0
  setpriv --reuid=nobody --regid=nogroup --clear-groups env -i PATH="$PATH" \
    node -e "require('http').createServer((q, r) => r.end('ok\\n')).listen(+process.argv[1])" "$DEMO_HTTP_PORT" &
  HTTP_PID=$!
}

servir () {
  importar_de_variable
  if [ ! -d "$COPIA" ]; then
    # Sin copia no hay nada que servir. Se espera en vez de salir: en Fly la preparación se
    # hace DENTRO de esta máquina (fly ssh console), y salir la metería en un bucle de reinicios.
    say "no copy in $COPIA: nothing to serve. Prepare it inside this container, then restart it:"
    say "  docker exec -it <container> /opt/demo/entrypoint.sh preparar"
    say "  fly ssh console -C '/opt/demo/entrypoint.sh preparar'"
    exec sleep infinity
  fi
  permisos_data
  machine_id
  limpiar_temporales
  firewall
  rm -rf "$RUN"
  cp -a "$COPIA" "$RUN"
  chmod 0755 "$RUN"   # `cp -a` le pasa el 0700 de la copia; dentro, cada carpeta tiene el suyo
  # Estado de ejecución que no debe venir de la copia: el pid de otro contenedor puede
  # coincidir con un proceso de este y hacer creer que ya corre otra bóveda u otro agente.
  rm -f "$RUN/vault/vault.lock" "$RUN/vault/state.json" "$RUN/maquina/agent.pid"

  say "serving $(cat "$DATA/address" 2>/dev/null) through $PROXY"
  as_vault dotrino-vaultd &
  local vpid=$!
  esperar_boveda
  as_tester dotrino-terminal-agent --dir "$RUN/maquina" --proxy "$PROXY" --shell /bin/bash &
  local apid=$!
  HTTP_PID=
  puerto_http
  # Apagable con DEMO_REQUESTS=0 (la demo queda como estaba: solo la terminal).
  local ppid=
  # En un subshell: si no se pueden montar, se dice y la terminal de la demo sigue sirviendo
  # (un `die` aquí metería el contenedor en un bucle de reinicios y tumbaría las dos demos).
  if [ "${DEMO_REQUESTS:-1}" = 1 ]; then
    if ( pedidos_de_muestra ); then bucle_de_pedidos & ppid=$!
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

case "${1:-servir}" in
  preparar) preparar ;;
  exportar) exportar "$@" ;;
  servir) servir ;;
  *) die "usage: preparar | servir | exportar" ;;
esac
