# Configuración de Supabase para Florería Muñiz

## 1. Crear y configurar el proyecto

1. Crea un proyecto Supabase.
2. En **SQL Editor**, ejecuta el contenido de `supabase/setup.sql`.
3. En el bloque final, añade los correos autorizados en `public.admins`. Usa el correo exacto que recibirá acceso con Google.
4. En **Authentication → Providers → Google**, activa Google y pega el Client ID y Client Secret que creaste en Google Cloud.
5. En **Authentication → URL Configuration**, añade como redirect permitido:
   - `https://florer-a-mu-iz.vercel.app/admin.html`
   - `http://localhost:3000/admin.html` para desarrollo local.
6. Copia el Project URL y la clave pública **anon/publishable** desde **Project Settings → API** en `supabase-config.js`:
   - `url`: URL del proyecto.
   - `anonKey`: clave pública anon o publishable.
7. No pegues nunca la clave `service_role` en el navegador, GitHub ni este archivo. RLS es la barrera de seguridad del cliente.
8. Espera a que Vercel despliegue y abre `/admin.html`.

## 2. Qué incluye

- Login Google en Supabase Auth y autorización por correo en `public.admins`.
- RLS: catálogo activo de lectura pública, escrituras y pedidos solo para admins.
- Bucket público `product-images`, con lecturas públicas, cargas y cambios de imagen restringidos a admins.
- Compresión de imagen a WebP en el navegador, con límite de 5 MB.
- Edición de producto, categoría, descripción, precio, nota, existencias y visibilidad.
- Registro de pedidos con precio y nombre históricos calculados en base de datos.
- RPC `get_top_selling_products`, que cuenta pedidos pagados o completados.

La web pública sigue mostrando el catálogo de respaldo hasta que se configure Supabase. Después carga el catálogo activo desde la base de datos.
