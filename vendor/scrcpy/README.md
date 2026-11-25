# scrcpy-server

`scrcpy-server` es el servidor de [scrcpy](https://github.com/Genymobile/scrcpy), versión 4.0, sin modificar
(SHA-256 `84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a`). Copyright de Genymobile y Romain Vimont,
con licencia Apache 2.0 (ver `LICENSE`).

Saguru lo copia a un Android conectado por USB y lo ejecuta en modo cámara para usar ese teléfono como fuente de la
herramienta Cámara. El archivo se borra del teléfono al arrancar.

Para actualizarlo: sustituye `scrcpy-server` por el de la nueva versión y escribe su número en `VERSION`; el servidor
solo arranca si se le pasa exactamente su propia versión.
