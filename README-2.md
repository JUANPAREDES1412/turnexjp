# Turnex — Control de Turnos, Nómina y Tareas (multi-empresa)

Aplicación de una sola página (`index.html`), sin necesidad de build ni servidor propio.
El "backend" es un proyecto Supabase (base de datos Postgres + API).

## Qué incluye

- **Propietario (control total):** crea empresas ilimitadas, crea administradores por empresa, gestiona tasas de cambio, cambia su propia clave.
- **Administrador de empresa:** crea/edita empleados, ubicaciones, programa turnos en un calendario, asigna tareas, liquida horas trabajadas (con cumplimiento de horas pactadas) en varias monedas, exporta reportes a Excel.
- **Empleado:** consulta su calendario de turnos, ve sus tareas asignadas, y cambia su propia clave. Sin acceso a nada más (según lo solicitado).
- Empresas con datos reales de Colombia, EE. UU., España y otros países (NIT/EIN/CIF, moneda por país, etc.).
- Exportación a Excel (.xlsx) de empleados, ubicaciones, tareas, turnos y nómina — generado en el propio navegador (sin servidor adicional).

## 1. Crear el proyecto en Supabase

1. Ve a https://supabase.com y crea un proyecto nuevo (gratis).
2. Entra a **SQL Editor → New query**, pega **todo** el contenido de `schema.sql` y dale **Run**.
3. En el mismo SQL Editor, crea el usuario propietario (una sola vez), reemplazando usuario y clave:
   ```sql
   select bootstrap_owner('admin', 'TuClaveSegura123', 'Propietario Principal');
   ```
4. Ve a **Project Settings → API** y copia:
   - **Project URL**
   - **anon public key**

## 2. Configurar la app

1. Abre `index.html` en el navegador (localmente, o ya publicado en GitHub Pages — ver paso 3).
2. La primera vez te pedirá la **Supabase URL** y la **anon public key**: pégalas ahí. Se guardan solo en el navegador (localStorage), no quedan en el código.
3. Inicia sesión en la pestaña **Propietario** con el usuario/clave que creaste con `bootstrap_owner`.
4. Desde el panel de propietario: crea tu primera empresa, luego crea un administrador para esa empresa (se genera una clave temporal que el administrador deberá cambiar en su primer ingreso).
5. El administrador inicia sesión en la pestaña **Empresa**, elige su empresa, y ya puede crear empleados, ubicaciones, turnos, tareas y liquidar nómina.

## 3. Subir a GitHub y publicar

```bash
git init
git add .
git commit -m "Turnex: app de control de turnos"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/TU_REPO.git
git push -u origin main
```

Para publicarla como sitio web gratuito con GitHub Pages:

1. En GitHub, entra al repositorio → **Settings → Pages**.
2. En "Source", elige la rama `main` y la carpeta `/ (root)`.
3. Guarda. En unos minutos tu app estará disponible en `https://TU_USUARIO.github.io/TU_REPO/index.html`.

## Estructura de archivos

- `index.html` — la aplicación completa (interfaz + lógica).
- `schema.sql` — todas las tablas, funciones y seguridad para Supabase.
- `README.md` — este archivo.

## ⚠️ Mejora de seguridad importante (aplicar si ya tenías la app instalada)

Si instalaste la app antes de esta actualización, tu base de datos tenía las tablas abiertas
(cualquier persona con la URL y la llave "anon" podía leer o modificar los datos directamente,
sin pasar por la app). Esto ya está corregido con un sistema de token de sesión real.

**Para aplicarlo:**
1. Ve a Supabase → **SQL Editor** → **New query**.
2. Copia y pega **todo** el contenido de `security_upgrade.sql` y dale **Run**.
3. Reemplaza tu `index.html` por la nueva versión que te entrego (ya incluye el manejo del token).
4. Todos los usuarios (propietario, administradores, empleados) deberán volver a iniciar sesión una vez.

Con esto:
- Ninguna tabla es accesible directamente sin un token de sesión válido (expira a las 12 horas).
- Un administrador solo puede ver/editar los datos de **su propia empresa**, nunca de otras.
- Un empleado solo puede **leer** sus propios turnos y tareas — no puede escribir nada ni ver datos de otros empleados.
- La contraseña (hash) nunca se envía al navegador, sin importar qué se consulte.
- Si instalas la app **desde cero** hoy, no necesitas `security_upgrade.sql` por separado: ya está incluido dentro de `schema.sql`.

## 🆕 Nuevas funcionalidades (aplicar si ya tenías la app instalada)

**Para aplicarlas:**
1. En Supabase → **Database → Extensions** → busca **pg_cron** → actívala (necesaria para la copia de seguridad diaria automática).
2. Ve a **SQL Editor** → **New query** → pega **todo** el contenido de `update_2.sql` → **Run**.
3. Reemplaza tu `index.html` por la nueva versión que te entrego.
4. Todos deberán volver a iniciar sesión una vez.

**Qué incluye esta actualización:**

- **Marcación de entrada/salida por el empleado.** El empleado ve un botón "Marcar entrada" en su turno del día, pero solo puede usarlo **desde 1 minuto antes** de la hora programada por el administrador (nunca antes) — esto se valida en la propia base de datos, no solo en la pantalla. Al marcar, el turno pasa a "En curso"; al marcar la salida, pasa a "Completado" y las horas reales quedan registradas para la nómina.
- **Control de inasistencias.** Si un turno programado ya pasó y el empleado nunca marcó su entrada, la app lo marca automáticamente como "Ausente". Desde Reportes puedes exportar un Excel de inasistencias por rango de fechas.
- **Nómina simplificada, sin conversión de moneda.** Cada empresa liquida en su propia moneda; ya no hay tasas de cambio ni "Tasas de cambio" en el panel del propietario.
- **Bloqueo de liquidaciones.** Cuando un administrador cierra la liquidación de un periodo con el botón "Cerrar liquidación de este periodo", ese rango de fechas queda bloqueado — no se puede volver a cerrar. Solo el **propietario** puede reabrirla, desde su pestaña "Liquidaciones cerradas".
- **Fotos en tareas especiales.** Al crear una tarea, el administrador puede marcar "Requiere foto de evidencia". El empleado verá un botón "Tomar foto" que abre la cámara del celular directamente; la foto queda guardada en la base de datos y visible para el administrador desde la lista de tareas.
- **Copias de seguridad.** Se genera automáticamente una copia diaria (3:00 a.m. UTC) de toda la información (empresas, usuarios, turnos, tareas, liquidaciones), y se conservan las últimas 30. El propietario puede generar una copia manual, descargarla como archivo, o restaurarla en caso de falla (acción irreversible, protegida con confirmación escrita). Las fotos de tareas no se incluyen en la copia para mantenerla liviana.
- **Uso desde celular o tablet.** La interfaz ahora se ajusta a pantallas pequeñas: tablas con desplazamiento horizontal, formularios y calendario adaptados, botones de ancho completo en móvil.

## Corrección de seguridad adicional encontrada durante esta actualización

Mientras implementaba lo anterior, detecté que algunas funciones internas (crear usuarios, restablecer claves, y la función que crea al propietario por primera vez) **no verificaban quién las estaba llamando** — cualquier persona con la llave "anon" podría haberlas invocado directamente. Ya quedaron corregidas en `update_2.sql`:
- `bootstrap_owner` ya no puede usarse para secuestrar la cuenta de un propietario existente.
- Crear administradores/empleados y restablecer claves ahora verifica que quien lo pide tenga el rol y la empresa correctos.
- Se separó el cambio de clave "propia" (autoservicio) del restablecimiento "administrativo" (hecho por otra persona), cada uno con su propia función y su propia verificación.

## Notas de seguridad (estado actual)

- Autenticación propia: usuario + clave con hash `bcrypt` (vía `pgcrypto`), no Supabase Auth.
- Cada login genera un **token de sesión** temporal (12 horas) que la app envía en cada petición.
  Las políticas de seguridad de la base de datos (RLS) usan ese token para limitar exactamente
  qué puede ver o modificar cada usuario: el propietario ve todo, un administrador solo su
  empresa, y un empleado solo puede leer (no escribir) sus propios turnos y tareas.
- Sin un token válido, la API de Supabase no entrega ni permite modificar ninguna fila —
  aunque alguien tenga la URL y la llave "anon" a mano.
- La contraseña (hash) nunca viaja al navegador en ninguna consulta.
- Si necesitas endurecerlo aún más (por ejemplo, exigir HTTPS estricto, rotar tokens con más
  frecuencia, o migrar por completo a Supabase Auth), puedo ayudarte a extenderlo.

## Cómo funciona el cálculo de nómina

- Se suman las horas de todos los **turnos marcados como "Completado"** dentro del rango de fechas elegido (más cualquier ajuste manual que se cargue en la tabla `time_entries`).
- Se compara contra las **horas semanales pactadas** del empleado × número de semanas del periodo, para mostrar el **% de cumplimiento**.
- El monto se calcula con la **tarifa por hora** y la **moneda propia del empleado**, y se convierte a la moneda que elijas usando las **tasas de cambio** configuradas por el propietario (pestaña "Tasas de cambio").
- Todo se puede exportar a Excel con un clic.

## Posibles próximos pasos (no incluidos aún)

- Registro de horas reales por reloj (clock-in/clock-out) en vez de solo turnos programados.
- Notificaciones por correo cuando se asigna un turno o tarea.
- Aprobación de nómina con firma/estado "pagado".
- Migración a Supabase Auth con RLS estricto por empresa.
