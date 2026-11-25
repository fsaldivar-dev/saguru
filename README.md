# Simuru

Superpoderes para el Simulador de iOS: una columna de acciones que se pega a su ventana y un CLI con las mismas acciones. Gratis, abierto y sin instalar nada dentro de tu app.

## Instalar

```bash
scripts/build.sh --install
```

Crea `build/Simuru.app` y enlaza el comando `simuru` en `/usr/local/bin` o `~/.local/bin`. Requiere macOS 14+ y Xcode.

## El panel

```bash
simuru
```

Aparece una columna a la derecha del Simulador. Lo sigue al moverlo y se oculta cuando el Simulador no está a la vista. No tiene icono en el Dock; se cierra con `simuru quit` o desde su menú `…`.

| Grupo | Botón | Qué hace |
|---|---|---|
| Inyectar | Notificación push | Elige app, título, texto y badge |
| | Añadir fotos y videos | Selector de archivos, o arrastra archivos a la columna |
| | Abrir URL | URLs y deep links |
| | Ubicación | Coordenadas o lugares guardados |
| | Permisos | Conceder, revocar o restablecer por app |
| Dispositivo | Claro / oscuro | Alterna la apariencia |
| | Barra de estado limpia | 9:41, batería y señal llenas |
| | Accesibilidad | Tamaño de texto y aumentar contraste |
| | Datos de la app | Abrir carpeta, borrar datos, reiniciar con otro idioma, editar User Defaults |
| Diseño | Superponer diseño | Una imagen sobre la pantalla, con opacidad ajustable |
| | Cuadrícula | En puntos, alineada a la pantalla |
| | Reglas | Coordenadas del cursor; ⌥ fija una guía y mide la distancia. No captura clics: la app sigue usable |
| | Cuentagotas | Copia el color como `Color` de SwiftUI |

Las herramientas de diseño necesitan el permiso de **Accesibilidad** (macOS lo pide la primera vez): es la única forma de saber dónde está exactamente la pantalla dentro de la ventana del Simulador. El resto del panel no necesita ningún permiso.

## El CLI

```bash
simuru devices
simuru apps
simuru push com.miempresa.miapp -t "Pedido en camino" -b "Llega en 10 minutos"
simuru push com.miempresa.miapp --payload payload.json
simuru media foto.jpg video.mp4
simuru url miapp://perfil/42
simuru location 19.4326 -99.1332        # o: simuru location clear
simuru privacy grant photos com.miempresa.miapp
simuru appearance toggle
simuru statusbar clean                  # o: reset
simuru textsize accessibility-large     # o: increment / decrement
simuru contrast on
simuru data open com.miempresa.miapp
simuru data erase com.miempresa.miapp --yes
simuru defaults com.miempresa.miapp
simuru defaults com.miempresa.miapp onboardingVisto true --type bool
simuru defaults com.miempresa.miapp onboardingVisto --delete
simuru relaunch com.miempresa.miapp --lang en --region US
```

Con varios simuladores arrancados, añade `-d "iPhone 17"` (nombre o UDID).

## Cómo funciona

- Todas las acciones pasan por `xcrun simctl` (`Simctl.swift`); no se usan frameworks privados.
- La columna localiza la ventana del Simulador con la lista pública de ventanas del sistema y se ordena justo encima de ella.
- La capa de diseño usa la API de Accesibilidad para leer el rectángulo de la pantalla del dispositivo.

## Límites conocidos

- El radio de las esquinas de la capa de diseño es aproximado.
- Accesibilidad cubre lo que `simctl` ofrece: tamaño de texto y contraste. Negrita, reducir movimiento y VoiceOver no.
- Si recompilas, macOS puede pedir de nuevo el permiso de Accesibilidad (la app se firma localmente).
- Fuera de alcance por ahora: red, cámara y captura de pantalla o video (esto último ya lo hace el Simulador).

## Licencia

[MIT](LICENSE)
