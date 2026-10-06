# Demo de Terminal para la revisión de Apple

Una bóveda y una máquina en **un contenedor**, para que App Review pruebe Dotrino Terminal
sin tener bóveda ni máquina propias. El revisor recibe una dirección `apple@AB12-CD34-EF56` y
una contraseña, entra con «Iniciar sesión» y la app le enseña «Máquina de prueba» con una
shell real.

No es una demo abierta: es una sola cuenta, para la revisión.

## Cómo está hecho

| Usuario | Corre | Puede tocar |
|---|---|---|
| `vault` | `dotrino-vaultd` | `/data/run/vault` (0700) y su socket en `/run/vault` (0700) |
| `tester` | `dotrino-terminal-agent` y las shells del revisor | su home y el enlace de la máquina |

- **Cada arranque restaura la copia** (`/data/copia` → `/data/run`), con el home del revisor
  incluido. Lo que cambie se pierde al reiniciar. La dirección no cambia: sale del perfil, que
  viaja en la copia.
- **El `machine-id` vive en el volumen** (`/data/machine-id`). De él sale la clave con la que la
  bóveda cifra su disco: sin él la copia no abre en otro contenedor (`kek-machine-changed`).
- La imagen no tiene binarios setuid. `/data` se atraviesa pero no se lista; la copia, el
  `machine-id` y la dirección solo los lee root.
- Paquetes de npm con versión fija (`VAULTD_VERSION`, `AGENT_VERSION` en el `Dockerfile`).

Lo prueban, desde [`dotrino-test`](https://github.com/imdotrino/dotrino-test),
`npm run smoke:demo-apple` (imagen, preparar, servir, aislamiento, reset y la copia por
variable) y `npm run smoke:demo-restaurar` (la copia en otro contenedor).

## Preparar (una vez)

```bash
docker build -t dotrino-demo-apple .
docker volume create demo-apple
docker run --rm -it -v demo-apple:/data dotrino-demo-apple preparar
```

Pide la contraseña del revisor dos veces (12 caracteres o más) y termina con la dirección.
Esa dirección y esa contraseña van en App Store Connect → *App Review Information* →
*Sign-in information*.

Preparar otra vez cambia la dirección: hay que borrar el volumen antes, y actualizar App Store
Connect después.

## Servir

```bash
docker run -d --name demo-apple --restart always \
  --cap-add NET_ADMIN -e DEMO_FIREWALL=1 -e DEMO_RESET_SECONDS=3600 \
  -v demo-apple:/data dotrino-demo-apple
```

| Variable | Qué hace |
|---|---|
| `DEMO_RESET_SECONDS` | el contenedor sale pasado ese tiempo y `--restart` lo levanta desde la copia |
| `DEMO_FIREWALL=1` | solo deja salir hacia el proxio (y el DNS). Necesita `NET_ADMIN`; si no puede aplicarse, no arranca |
| `DEMO_PROXY` | el proxio (por defecto `wss://proxy.dotrino.com`) |
| `DEMO_COPIA_B64`, o `DEMO_COPIA_B64_1`, `_2`… | la copia (sale de `exportar`; `exportar 8000` la parte en líneas de 8000, una por variable), para plataformas sin disco persistente |
| `DEMO_HTTP_PORT` | contesta `ok` en ese puerto, para la plataforma que exige uno |
| `DEMO_USER` / `DEMO_MACHINE_NAME` | solo al preparar: el usuario (`apple`) y el nombre de la máquina |

## Dónde corre: Timone

[Timone](https://timone.dev) construye este repo (el `Dockerfile` de la raíz) y lo corre en
Kubernetes. Las apps de Timone **no tienen disco persistente**, y no hace falta: la copia no
cambia después de preparada, así que llega por la variable `DEMO_COPIA_B64`, y cada contenedor
nuevo es un reset. Timone limita cada variable a 8192 caracteres y la copia ronda los 56 000
(la identidad va cifrada y no se comprime), así que va en trozos `DEMO_COPIA_B64_1`, `_2`…

- **La copia nunca va en el repo ni en la imagen.** Lleva la bóveda de la demo: quien la tenga
  controla la cuenta (cambia la contraseña del revisor, se añade aparatos). La variable solo la
  ve el dueño en el panel.
- **Preparar** se hace donde haya disco (en local, con un volumen de Docker) y luego se exporta:

```bash
docker run --rm -it -v demo-apple:/data dotrino-demo-apple preparar
docker run --rm -v demo-apple:/data dotrino-demo-apple exportar 8000   # una línea por variable DEMO_COPIA_B64_<n>
```

- La app se crea por la API (`POST /projects` con este repo) con las variables en `envVars`:
  los trozos `DEMO_COPIA_B64_<n>`, `DEMO_HTTP_PORT=8080` y `DEMO_RESET_SECONDS=3600`. Cada push a
  `main` redespliega solo (Timone registra un webhook), y redesplegar también es un reset.

**En marcha** desde el 2026-10-06: proyecto `cmuw6jfpp00107hgeav2mbj12`,
`imdotrino-dotrino-demo-apple.timone.dev` (esa URL solo contesta `ok`; la demo se usa desde la
app). Lo que dice la primera línea del log, comprobado allí:

- corre como **root** con las capacidades por defecto de Docker (`CapEff a80425fb`): hay
  `SETUID`/`SETGID`, así que los dos usuarios funcionan y el revisor no lee la bóveda;
- **no hay `NET_ADMIN`**: el firewall va apagado y la shell del revisor tiene salida a internet.
  Aceptado por el dueño (Timone es un servicio en desarrollo de un conocido).

Logs: `GET /projects/<id>/logs?tail=200` con el token de la API (Settings → API tokens).
