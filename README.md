# OCI Bastion para macOS

Primera versión de una app SwiftUI para crear y mantener una sesión SOCKS5 de OCI Bastion y abrir conexiones SSH a instancias privadas.

## Requisitos

- macOS 14 o posterior (preparada para macOS Tahoe).
- OCI CLI configurado en `/opt/homebrew/bin/oci` o `/usr/local/bin/oci`.
- Claves SSH del Bastion y de las instancias, y permisos OCI para consultar y crear sesiones.
- Acceso de red al Bastion desde una IP incluida en su lista permitida.

## Compilar y abrir

```sh
./Scripts/build-app.sh
open "dist/OCI Bastion.app"
```

El icono fuente está en `Assets/AppIcon.png`. Si se modifica, ejecuta `Scripts/build-icon.sh` para regenerar `Assets/AppIcon.icns`.

La compilación local genera una firma ad hoc. Para distribuir la app a otros Macs se necesitaría firmarla y notarizarla con una cuenta Apple Developer.

## Uso

1. Selecciona el archivo `~/.oci/config` y un perfil.
2. Pulsa **Cargar compartimentos** para obtener los primeros 100, usa **Cargar 100 más** si quedan páginas, selecciona el compartimento por nombre y pulsa **Buscar bastiones**. También puedes introducir un OCID de compartimento manualmente si tu perfil no tiene permiso para listarlos.
3. Selecciona las claves pública y privada del Bastion. Si tu clave privada tiene contraseña, cárgala previamente en `ssh-agent`.
4. Pulsa **Conectar Bastion**. La app crea una sesión si no puede reutilizar una sesión propia activa.
5. Añade destinos SSH con IP privada, usuario, puerto y clave privada de la instancia. Elige **Terminal** o **iTerm2**, pulsa **Abrir SSH** o copia el comando para ejecutarlo a mano.
6. En **Túneles SSH locales** puedes añadir una conexión SSH con puerto local (origen), host remoto y puerto remoto (destino). **Abrir túnel** ejecuta un reenvío `ssh -N -L` en la terminal elegida; **Copiar SSH** copia el comando. Necesita que el SOCKS5 del Bastion esté activo.
7. Usa **Guardar como…** para guardar los datos actuales con un nombre. El desplegable permite cargarlos después; **Actualizar**, **Renombrar…** y **Eliminar** gestionan la conexión seleccionada.
8. **Exportar configuración…** permite guardar todo o solo la configuración activa. Si está seleccionada una conexión con nombre, la exportación individual conserva ese nombre e incluye los cambios visibles, así como sus destinos y túneles SSH.
9. **Importar configuración…** añade conexiones sin eliminar las existentes. Si el archivo contiene `current` o alguna conexión con un nombre ya guardado, muestra qué se sobrescribirá y pide confirmación. La importación está deshabilitada mientras hay un túnel Bastion activo. Los archivos de la versión anterior siguen siendo compatibles.
10. **Limpiar campos** restablece el formulario actual y deselecciona la conexión cargada. Las conexiones guardadas permanecen en el desplegable.

**Copiar SSH Bastion** copia el comando del túnel correspondiente a la sesión OCI activa. **Copiar SSH** en un destino copia su comando de acceso; requiere que el túnel SOCKS5 esté activo cuando se ejecute.

El proxy corporativo HTTP CONNECT se detecta automáticamente a partir de `http_proxy`, la configuración del sistema o `http://wpad/wpad.dat`, en ese orden. Se usa tanto para OCI CLI como para el túnel SSH. También puedes elegir un proxy manual o conexión directa. La configuración se guarda en `~/Library/Application Support/OCIBastion/settings.json`, con permisos `0600`. No se guardan claves privadas ni contraseñas.

La app solo mantiene el túnel mientras está abierta. Al cerrar la app, el túnel se detiene. Una sesión OCI creada puede continuar activa hasta que caduque.

Los campos de puerto muestran números sin separadores de miles. Antes de conectar, la app comprueba si el puerto SOCKS5 está ocupado. Si detecta un SSH anterior identificado mediante su marca de propiedad, lo detiene y espera a que libere el puerto; si el proceso no es suyo, muestra su PID y deja el puerto intacto. Al pulsar **Desconectar**, espera a que termine el SSH antes de permitir otra conexión.

El archivo exportado incluye rutas de las claves, perfiles, OCID y destinos, pero no contiene las claves ni credenciales de OCI. Se crea con permisos `0600`; al importarlo en otro Mac quizá debas ajustar las rutas locales.

Para verificar importación, exportación y comandos `ssh -L`, ejecuta `./Scripts/test-archive.sh`. Los archivos JSON de `Tests/` sirven para probar una importación completa del formato antiguo y otra de una conexión con nombre sin `current`.

## Código fuente y datos locales

El repositorio contiene la app Swift en `Sources/OCIBastion`, los recursos en `Assets`, los scripts de compilación en `Scripts` y ejemplos anonimizados en `Tests`.

La carpeta `Tests/LocalFixtures` conserva archivos de prueba personales solo en este equipo y está excluida de Git. También se excluyen `.build`, `dist`, claves, archivos de configuración SSH y datos de ejecución. Cada usuario debe aportar su propio `~/.oci/config` y sus propias claves; la app guarda únicamente sus rutas en `~/Library/Application Support/OCIBastion/settings.json`.

Para publicar el código en GitHub, crea un repositorio vacío en la cuenta `israelgoracle`, añade su URL como remoto `origin` y sube la rama `main`. Los binarios de `dist` se distribuyen aparte del código fuente.
