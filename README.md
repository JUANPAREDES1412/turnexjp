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
