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

## Notas importantes de seguridad

- Esta app usa un sistema de autenticación **propio** (usuario + clave guardados con hash `bcrypt` vía `pgcrypto`), no el sistema de Supabase Auth. Esto permite que el propietario cree usuarios con ID y clave simples, como pediste.
- Debido a que es un sitio estático (sin servidor propio) que habla directo con Supabase usando la llave `anon`, las políticas de seguridad a nivel de fila (RLS) están abiertas para que la app funcione de forma sencilla. Esto es razonable para **uso interno/controlado**, pero **no aísla criptográficamente los datos entre empresas** a nivel de base de datos — cualquier persona con la URL y la llave anon técnicamente podría consultar la API directamente.
- Si vas a manejar información sensible o vas a exponer esto públicamente, la recomendación es migrar a **Supabase Auth + políticas RLS por `company_id`**, o agregar una capa de backend (Supabase Edge Functions) que valide la sesión antes de tocar las tablas. Puedo ayudarte a hacer esa migración si lo necesitas.
- Cambia la clave de propietario (`bootstrap_owner`) por una robusta y no la compartas.

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
