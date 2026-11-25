# Saguru

Superpoderes para el Simulador de iOS: una columna de acciones que se pega a su ventana y un CLI con las mismas acciones. Gratis, abierto y sin instalar nada dentro de tu app.

## Instalar

```bash
scripts/build.sh --install
```

Crea `build/Saguru.app` y enlaza el comando `saguru` en `/usr/local/bin` o `~/.local/bin`. Requiere macOS 14+ y Xcode.

## El panel

```bash
saguru
```

Aparece una columna a la derecha del Simulador. Lo sigue al moverlo y se oculta cuando el Simulador no está a la vista. No tiene icono en el Dock; se cierra con `saguru quit` o desde su menú `…`.

Arriba de la columna está la **app activa**: se elige una vez (simulador y app, con buscador) y vale para todo lo
que depende de una app: notificaciones, permisos y datos. Se recuerda por simulador.

| Grupo | Botón | Qué hace |
|---|---|---|
| Inyectar | Notificación push | Título, subtítulo, texto, badge, sonido y datos propios; vista JSON para editar el payload o abrir un `.apns`. Avisa antes de enviar si la app no tiene permiso de notificaciones |
| | Galería | Popover con las fotos y videos del simulador: añadir (botón o arrastrando), seleccionar varias, exportar (botón o arrastrando a Finder) y eliminar. También se pueden soltar archivos sobre la columna |
| | Deep links | Abre URLs y deep links. Muestra los esquemas y dominios que declara la app activa, y guarda favoritos e historial por app. Las rutas no se pueden leer de la app: se guardan las que uses |
| | Ubicación | Un mapa donde eliges el punto con un clic, buscador de lugares y coordenadas editables |
| | Permisos | Cuadrícula con los permisos que la app declara en su Info.plist y su estado real: Preguntar, Limitado (ubicación al usar la app, fotos solo añadir), Permitir o Nunca. Notificaciones se muestra pero solo la app puede pedirlo |
| Dispositivo | Apariencia | Claro u oscuro, y «Comparar»: la otra apariencia sobre media pantalla, con un tirador para deslizar. Un lado es la app en vivo; el otro es una foto que se vuelve a tomar sola, unos segundos después de que la pantalla cambie y se quede quieta |
| | Barra de estado | Eliges cada parte: hora, Wi-Fi (conectado o apagado, e intensidad), red celular (con señal, buscando, sin servicio u oculta; barras y tipo de datos: 5G, LTE, 4G, 3G) y batería. «Valores de catálogo» pone 9:41, señal completa y batería llena |
| | Accesibilidad | **Navegador**: numera los elementos sobre la pantalla en el orden de VoiceOver; ↑ ↓ los recorren, ← → cambian el rotor e Intro activa el elemento. **Árbol**: roles, etiquetas e identificadores (copiables), con resaltado. **Auditoría**: controles sin etiqueta, objetivos táctiles pequeños, contraste bajo, etiquetas e identificadores repetidos, con puntuación. **Ajustes**: animaciones lentas, tamaño de texto, aumentar contraste, texto en negrita, reducir transparencia, reducir movimiento, invertir colores, formas de botón, etiquetas de encendido y diferenciar sin color |
| | Datos de la app | **Preferencias**: los User Defaults en una tabla, editables. **Bases de datos**: las SQLite de la app (Core Data, SwiftData…), sus tablas y un editor de consultas de solo lectura; el resultado se copia como tabla. **Archivos**: el contenedor con tamaños. **Acciones**: abrir carpeta, borrar datos, reiniciar en otro idioma |
| | Red | Ventana con cada petición que hace la app: URL, método, estado, tiempo y tamaño; cabeceras, parámetros y cuerpos de petición y respuesta (JSON con formato, texto, imagen o binario, que se puede guardar); copiar como cURL. **Crear mock** convierte una petición capturada en una respuesta guardada, editable (estado, cabeceras, cuerpo, espera) y con interruptor. Sin proxy ni certificados |
| Diseño | Cuadrícula | Rejilla de 2, 4, 8 o 16 pt y columnas de maquetación, con medidas por jerarquía como en una herramienta de diseño: detecta los contenedores (tarjetas, barras, chips), mide cada caja contra la de al lado o contra la pared de su contenedor, y se puede entrar en un contenedor para medir lo de dentro. Verde si las medidas son múltiplos del paso, naranja si no |
| | Reglas | Coordenadas del cursor; ⌥ fija una guía y mide la distancia. No captura clics: la app sigue usable |
| | Colores | Paleta de la pantalla (colores en uso y cuánto ocupan), los colores con nombre del catálogo de la app, y un cuentagotas. Un clic copia el color como `Color` de SwiftUI |

Las herramientas de diseño necesitan el permiso de **Accesibilidad** (macOS lo pide la primera vez): es la única forma de saber dónde está exactamente la pantalla dentro de la ventana del Simulador. El resto del panel no necesita ningún permiso.

## El CLI

```bash
saguru devices
saguru apps
saguru push com.miempresa.miapp -t "Pedido en camino" -b "Llega en 10 minutos"
saguru push com.miempresa.miapp --payload payload.json
saguru media foto.jpg video.mp4
saguru url miapp://perfil/42
saguru location 19.4326 -99.1332        # o: saguru location clear
saguru privacy grant photos com.miempresa.miapp
saguru appearance toggle
saguru statusbar clean                  # o: reset
saguru textsize accessibility-large     # o: increment / decrement
saguru contrast on
saguru data open com.miempresa.miapp
saguru data erase com.miempresa.miapp --yes
saguru defaults com.miempresa.miapp
saguru defaults com.miempresa.miapp onboardingVisto true --type bool
saguru defaults com.miempresa.miapp onboardingVisto --delete
saguru relaunch com.miempresa.miapp --lang en --region US
saguru query com.miempresa.miapp "SELECT * FROM ZUSUARIO LIMIT 10" --db default.store
```

Con varios simuladores arrancados hay que elegir uno con `-d "iPhone 17"` (nombre o UDID); Saguru no adivina.

`push` comprueba que la app esté instalada y avisa si iOS no va a mostrar la notificación porque la app no tiene
permiso de notificaciones (denegado, o nunca lo pidió). `--payload` acepta cualquier JSON de APNs: subtítulo,
sonido, `thread-id`, datos propios.

## Cómo funciona

- Las acciones pasan por `xcrun simctl` (`Simctl.swift`); no se usan frameworks privados.
- La galería lee la fototeca del simulador directamente de sus archivos en esta Mac (solo lectura), y los permisos
  de notificaciones, del archivo donde iOS los guarda.
- La columna localiza la ventana del Simulador con la lista pública de ventanas del sistema y se ordena justo encima de ella.
- La capa de diseño usa la API de Accesibilidad para leer el rectángulo de la pantalla del dispositivo.
- El monitor de red relanza la app con una pequeña biblioteca dentro (`agent/SaguruAgent.m`, cargada con
  `DYLD_INSERT_LIBRARIES`; nada se añade a tu proyecto). Esa biblioteca ve las peticiones de `URLSession`, las
  escribe en una carpeta temporal que Saguru lee, y responde con los mocks activos. Los mocks se guardan por app en
  `~/Library/Application Support/Saguru/mocks/<bundle id>/`.

## Límites conocidos

- La cuadrícula combina dos fuentes: los elementos que la app expone a accesibilidad y los contenedores que detecta
  por su fondo en una captura. Un contenedor sin fondo propio (un simple `VStack`) no se ve, y los bordes detectados
  tienen medio punto de margen de error.
- Los nombres de color salen del catálogo de recursos compilado. Los colores definidos en código no conservan nombre.

- Las bases de datos se abren en solo lectura: se consultan, no se modifican. Los cambios en User Defaults los lee
  la app la próxima vez que arranca.

- La hora de la barra de estado debe ir como `9:41`; el simulador rechaza otros formatos y, curiosamente, las horas
  en punto (`12:00`).

- Eliminar fotos reconstruye la fototeca: el simulador no permite borrar una foto suelta, así que Saguru la vacía y
  vuelve a añadir las demás. Se pierden los álbumes, favoritos y ediciones hechos dentro del simulador, y Fotos
  vuelve a mostrar su pantalla de bienvenida.

- El radio de las esquinas de la capa de diseño es aproximado.
- El inspector de accesibilidad lee el árbol que el Simulador expone a macOS, así que necesita el permiso de
  Accesibilidad y que la ventana del Simulador esté en el escritorio actual. VoiceOver no se enciende: el orden y lo
  que «se leería» se deducen del árbol. El contraste de la auditoría es una estimación sobre una captura.
- Los ajustes de accesibilidad que `simctl` no cubre se escriben en las preferencias del simulador. Falta la
  escala de grises: no se pudo confirmar que surta efecto.
- Saguru pide el permiso de Accesibilidad al arrancar si no lo tiene; macOS lo aplica tras relanzar. `scripts/build.sh`
  firma con tu certificado «Apple Development» si existe, y así el permiso sobrevive a las recompilaciones; sin
  certificado la firma es local y macOS lo vuelve a pedir tras cada build.
- El monitor de red solo ve lo que pasa por `URLSession` (también Alamofire y similares). No ve gRPC (Firestore),
  WebSockets, `WKWebView` ni sockets propios. Solo captura si Saguru lanzó la app: al lanzarla desde Xcode hay que
  volver a pulsar Capturar. Un mock responde a un método y una URL sin mirar los parámetros; de cada cuerpo se
  guardan como mucho 8 MB. Las subidas por archivo o stream largo no se han probado.
- Fuera de alcance por ahora: cámara y captura de pantalla o video (esto último ya lo hace el Simulador).

## Licencia

[MIT](LICENSE)
