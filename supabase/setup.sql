-- Florería Muñiz: catálogo, ventas, roles, Storage y funciones del panel.
-- Ejecutar completo en Supabase Dashboard > SQL Editor.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$ BEGIN
  CREATE TYPE public.order_status AS ENUM ('pending','paid','cancelled','completed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS admins_email_lower_unique ON public.admins (lower(email));

CREATE TABLE IF NOT EXISTS public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalog_key text UNIQUE,
  name varchar(255) NOT NULL,
  category varchar(80) NOT NULL DEFAULT 'Ramos y arreglos',
  description text,
  price numeric(10,2) NOT NULL CHECK (price >= 0),
  price_note text,
  image_url text,
  stock integer NOT NULL DEFAULT 0 CHECK (stock >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS catalog_key text;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS category varchar(80) NOT NULL DEFAULT 'Ramos y arreglos';
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS price_note text;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS stock integer NOT NULL DEFAULT 0;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS products_catalog_key_unique ON public.products(catalog_key);

CREATE TABLE IF NOT EXISTS public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name varchar(255) NOT NULL,
  customer_phone varchar(50),
  status public.order_status NOT NULL DEFAULT 'pending',
  total_amount numeric(10,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  product_name_snapshot varchar(255),
  unit_price_snapshot numeric(10,2),
  quantity integer NOT NULL CHECK (quantity > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Bring forward tables created from the earlier draft schema, if present.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.orders ALTER COLUMN customer_phone DROP NOT NULL;
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS product_name_snapshot varchar(255);
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS unit_price_snapshot numeric(10,2);

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='order_items' AND column_name='unit_price'
  ) THEN
    EXECUTE 'UPDATE public.order_items SET unit_price_snapshot=coalesce(unit_price_snapshot,unit_price,0) WHERE unit_price_snapshot IS NULL';
  ELSE
    UPDATE public.order_items SET unit_price_snapshot=coalesce(unit_price_snapshot,0) WHERE unit_price_snapshot IS NULL;
  END IF;
END;
$migration$;
UPDATE public.order_items oi
SET product_name_snapshot=coalesce(p.name,'Producto eliminado')
FROM public.products p
WHERE oi.product_id=p.id AND oi.product_name_snapshot IS NULL;
UPDATE public.order_items
SET product_name_snapshot='Producto eliminado'
WHERE product_name_snapshot IS NULL;
ALTER TABLE public.order_items ALTER COLUMN product_name_snapshot SET NOT NULL;
ALTER TABLE public.order_items ALTER COLUMN unit_price_snapshot SET NOT NULL;

ALTER TABLE public.order_items DROP CONSTRAINT IF EXISTS order_items_order_id_fkey;
ALTER TABLE public.order_items ADD CONSTRAINT order_items_order_id_fkey
  FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE RESTRICT;
ALTER TABLE public.order_items DROP CONSTRAINT IF EXISTS order_items_product_id_fkey;
ALTER TABLE public.order_items ADD CONSTRAINT order_items_product_id_fkey
  FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS order_items_order_id_idx ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS order_items_product_id_idx ON public.order_items(product_id);
CREATE INDEX IF NOT EXISTS orders_status_created_at_idx ON public.orders(status,created_at DESC);

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS products_set_updated_at ON public.products;
CREATE TRIGGER products_set_updated_at BEFORE UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS orders_set_updated_at ON public.orders;
CREATE TRIGGER orders_set_updated_at BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Security-definer helper prevents recursive RLS checks on the admins table.
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins a
    WHERE lower(a.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  );
$$;
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admins_read_self ON public.admins;
CREATE POLICY admins_read_self ON public.admins FOR SELECT TO authenticated
USING (lower(email) = lower(coalesce((select auth.jwt() ->> 'email'), '')));

DROP POLICY IF EXISTS products_public_read ON public.products;
CREATE POLICY products_public_read ON public.products FOR SELECT TO anon, authenticated
USING (is_active = true);
DROP POLICY IF EXISTS products_admin_all ON public.products;
CREATE POLICY products_admin_all ON public.products FOR ALL TO authenticated
USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS orders_admin_all ON public.orders;
CREATE POLICY orders_admin_all ON public.orders FOR ALL TO authenticated
USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS order_items_admin_all ON public.order_items;
CREATE POLICY order_items_admin_all ON public.order_items FOR ALL TO authenticated
USING (public.is_admin()) WITH CHECK (public.is_admin());

GRANT SELECT ON public.products TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.products TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admins, public.orders, public.order_items TO authenticated;

-- Public bucket for catalog photos. Upload/update/delete remain admin-only.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('product-images','product-images',true,5242880,ARRAY['image/png','image/jpeg','image/webp'])
ON CONFLICT (id) DO UPDATE SET public=true,file_size_limit=5242880,allowed_mime_types=EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS product_images_public_read ON storage.objects;
CREATE POLICY product_images_public_read ON storage.objects FOR SELECT TO anon, authenticated
USING (bucket_id = 'product-images');
DROP POLICY IF EXISTS product_images_admin_insert ON storage.objects;
CREATE POLICY product_images_admin_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'product-images' AND public.is_admin());
DROP POLICY IF EXISTS product_images_admin_update ON storage.objects;
CREATE POLICY product_images_admin_update ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'product-images' AND public.is_admin())
WITH CHECK (bucket_id = 'product-images' AND public.is_admin());
DROP POLICY IF EXISTS product_images_admin_delete ON storage.objects;
CREATE POLICY product_images_admin_delete ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'product-images' AND public.is_admin());

-- Top sellers count only paid or completed orders.
CREATE OR REPLACE FUNCTION public.get_top_selling_products(limit_count integer DEFAULT 5)
RETURNS TABLE(product_id uuid, product_name text, total_units_sold bigint, total_revenue numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Administrator access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT oi.product_id,
         coalesce(p.name, oi.product_name_snapshot)::text,
         sum(oi.quantity)::bigint,
         sum(oi.quantity * oi.unit_price_snapshot)::numeric
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  LEFT JOIN public.products p ON p.id = oi.product_id
  WHERE o.status IN ('paid','completed')
  GROUP BY oi.product_id,p.name,oi.product_name_snapshot
  ORDER BY sum(oi.quantity) DESC, coalesce(p.name,oi.product_name_snapshot) ASC
  LIMIT greatest(1,least(coalesce(limit_count,5),50));
END;
$$;
REVOKE ALL ON FUNCTION public.get_top_selling_products(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_top_selling_products(integer) TO authenticated;

-- Creates order rows and historical line snapshots from current DB prices.
CREATE OR REPLACE FUNCTION public.create_admin_order(
  p_customer_name text,
  p_customer_phone text,
  p_status public.order_status,
  p_items jsonb
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_order_id uuid;
  item record;
  product_row record;
  computed_total numeric(10,2) := 0;
  item_count integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Administrator access required' USING ERRCODE = '42501';
  END IF;
  IF nullif(trim(p_customer_name),'') IS NULL THEN
    RAISE EXCEPTION 'Customer name is required';
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Order items must be a JSON array';
  END IF;
  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'At least one order item is required';
  END IF;

  INSERT INTO public.orders(customer_name,customer_phone,status,total_amount)
  VALUES(trim(p_customer_name),nullif(trim(coalesce(p_customer_phone,'')),''),p_status,0)
  RETURNING id INTO new_order_id;

  FOR item IN
    SELECT * FROM jsonb_to_recordset(p_items) AS x(product_id uuid, quantity integer)
  LOOP
    IF item.product_id IS NULL OR item.quantity IS NULL OR item.quantity < 1 THEN
      RAISE EXCEPTION 'Each item needs a product and positive quantity';
    END IF;
    SELECT id,name,price INTO product_row FROM public.products WHERE id=item.product_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product not found'; END IF;
    INSERT INTO public.order_items(order_id,product_id,product_name_snapshot,unit_price_snapshot,quantity)
    VALUES(new_order_id,product_row.id,product_row.name,product_row.price,item.quantity);
    computed_total := computed_total + product_row.price * item.quantity;
    item_count := item_count + 1;
  END LOOP;

  IF item_count = 0 THEN RAISE EXCEPTION 'At least one valid order item is required'; END IF;
  UPDATE public.orders SET total_amount=computed_total WHERE id=new_order_id;
  RETURN new_order_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_admin_order(text,text,public.order_status,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_admin_order(text,text,public.order_status,jsonb) TO authenticated;

-- Seed the site's current catalog once. Re-running this file preserves later edits.
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-01','Referencia #01','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',1100,'Precio sujeto a cambios.','/assets/catalogo/001.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-02','Referencia #02','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',1200,'Precio sujeto a cambios.','/assets/catalogo/002.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-03','Referencia #03','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',2100,'Precio sujeto a cambios.','/assets/catalogo/003.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-04','Referencia #04','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',2050,'Precio sujeto a cambios.','/assets/catalogo/004.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-05','Referencia #05','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',2300,'Precio sujeto a cambios.','/assets/catalogo/005.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-06','Referencia #06','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',2480,'Precio sujeto a cambios.','/assets/catalogo/006.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-07','Referencia #07','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',1350,'Precio sujeto a cambios.','/assets/catalogo/007.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-08','Referencia #08','Ramos buchones','Producto del Catálogo Ramos y arreglos 2026.',1000,'Precio sujeto a cambios.','/assets/catalogo/008.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-09','Referencia #09','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',850,'Precio sujeto a cambios.','/assets/catalogo/009.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-10','Referencia #10','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',250,'','/assets/catalogo/010.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-11','Referencia #11','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',370,'','/assets/catalogo/011.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-12','Referencia #12','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2500,'','/assets/catalogo/012.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-13','Referencia #13','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2950,'Precio sujeto a cambios.','/assets/catalogo/013.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-14','Referencia #14','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1700,'Precio sujeto a cambios.','/assets/catalogo/014.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-15','Referencia #15','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',350,'Precio sujeto a cambios.','/assets/catalogo/015.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-16','Referencia #16','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1400,'Precio sujeto a cambios.','/assets/catalogo/016.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-17','Referencia #17','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2150,'Precio sujeto a cambios.','/assets/catalogo/017.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-18','Referencia #18','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',320,'','/assets/catalogo/018.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-19','Referencia #19','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',900,'Precio sujeto a cambios.','/assets/catalogo/019.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-20','Referencia #20','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2000,'Precio sujeto a cambios.','/assets/catalogo/020.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-21','Referencia #21','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',300,'','/assets/catalogo/021.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-22','Referencia #22','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',480,'','/assets/catalogo/022.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-23','Referencia #23','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',220,'','/assets/catalogo/023.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-24','Referencia #24','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',420,'','/assets/catalogo/024.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-25','Referencia #25','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1400,'Precio sujeto a cambios.','/assets/catalogo/025.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-26','Referencia #26','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1100,'','/assets/catalogo/026.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-27','Referencia #27','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1750,'La imagen muestra un diseño con mensaje oculto.','/assets/catalogo/027.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-28','Referencia #28','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2100,'','/assets/catalogo/028.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-29','Referencia #29','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',850,'Precio sujeto a cambios.','/assets/catalogo/029.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-30','Referencia #30','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',500,'','/assets/catalogo/030.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-31','Referencia #31','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1850,'','/assets/catalogo/031.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-32','Referencia #32','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',550,'','/assets/catalogo/032.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-33','Referencia #33','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',450,'','/assets/catalogo/033.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-34','Referencia #34','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1000,'Los tulipanes se piden con anticipación; precio variable.','/assets/catalogo/034.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-35','Referencia #35','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',900,'','/assets/catalogo/035.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-36','Referencia #36','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',800,'No incluye botella.','/assets/catalogo/036.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-37','Referencia #37','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',750,'','/assets/catalogo/037.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-38','Referencia #38','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1200,'','/assets/catalogo/038.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-39','Referencia #39','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',490,'','/assets/catalogo/039.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-40','Referencia #40','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',360,'','/assets/catalogo/040.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-41','Referencia #41','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',650,'','/assets/catalogo/041.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-42','Referencia #42','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',360,'','/assets/catalogo/042.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-43','Referencia #43','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',680,'','/assets/catalogo/043.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-44','Referencia #44','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',570,'','/assets/catalogo/044.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-45','Referencia #45','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1200,'','/assets/catalogo/045.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-46','Referencia #46','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1100,'Precio sujeto a cambios.','/assets/catalogo/046.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-47','Referencia #47','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',800,'','/assets/catalogo/047.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-48','Referencia #48','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2200,'','/assets/catalogo/048.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-49','Referencia #49','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',900,'','/assets/catalogo/049.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-50','Referencia #50','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',750,'','/assets/catalogo/050.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-51','Referencia #51','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1450,'','/assets/catalogo/051.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-52','Referencia #52','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1250,'','/assets/catalogo/052.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-53','Referencia #53','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1100,'','/assets/catalogo/053.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-54','Referencia #54','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2900,'','/assets/catalogo/054.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-55','Referencia #55','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2200,'','/assets/catalogo/055.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-56','Referencia #56','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',500,'No incluye la fruta.','/assets/catalogo/056.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-57','Referencia #57','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',450,'','/assets/catalogo/057.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-58','Referencia #58','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',1400,'','/assets/catalogo/058.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('ramos-59','Referencia #59','Ramos y arreglos','Producto del Catálogo Ramos y arreglos 2026.',2100,'','/assets/catalogo/059.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-01','Referencia #01','Fúnebres','Producto del Catálogo Fúnebre 2026.',650,'','/assets/catalogo/060.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-02','Referencia #02','Fúnebres','Producto del Catálogo Fúnebre 2026.',750,'','/assets/catalogo/061.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-03','Referencia #03','Fúnebres','Producto del Catálogo Fúnebre 2026.',850,'','/assets/catalogo/062.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-04','Referencia #04','Fúnebres','Producto del Catálogo Fúnebre 2026.',1000,'','/assets/catalogo/063.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-05','Referencia #05','Fúnebres','Producto del Catálogo Fúnebre 2026.',850,'','/assets/catalogo/064.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-06','Referencia #06','Fúnebres','Producto del Catálogo Fúnebre 2026.',1100,'','/assets/catalogo/065.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-07','Referencia #07','Fúnebres','Producto del Catálogo Fúnebre 2026.',1000,'','/assets/catalogo/066.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-08','Referencia #08','Fúnebres','Producto del Catálogo Fúnebre 2026.',2500,'','/assets/catalogo/067.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-09','Referencia #09','Especiales','Producto del Catálogo Fúnebre 2026.',1300,'','/assets/catalogo/068.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-10','Referencia #10','Especiales','Producto del Catálogo Fúnebre 2026.',1100,'','/assets/catalogo/069.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-11','Referencia #11','Especiales','Producto del Catálogo Fúnebre 2026.',2200,'','/assets/catalogo/070.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-12','Referencia #12','Especiales','Producto del Catálogo Fúnebre 2026.',2000,'','/assets/catalogo/071.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-13','Referencia #13','Especiales','Producto del Catálogo Fúnebre 2026.',1900,'','/assets/catalogo/072.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-14','Referencia #14','Especiales','Producto del Catálogo Fúnebre 2026.',1100,'','/assets/catalogo/073.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-15','Referencia #15','Especiales','Producto del Catálogo Fúnebre 2026.',2800,'Base rentada.','/assets/catalogo/074.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-16','Referencia #16','Especiales','Producto del Catálogo Fúnebre 2026.',2000,'Base rentada.','/assets/catalogo/075.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-17','Referencia #17','Especiales','Producto del Catálogo Fúnebre 2026.',2100,'Base rentada.','/assets/catalogo/076.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-18','Referencia #18','Especiales','Producto del Catálogo Fúnebre 2026.',2900,'Base rentada.','/assets/catalogo/077.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-19','Referencia #19','Especiales','Producto del Catálogo Fúnebre 2026.',2500,'Base rentada.','/assets/catalogo/078.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-20','Referencia #20','Especiales','Producto del Catálogo Fúnebre 2026.',2200,'Base rentada. Incluye solo 4 letras.','/assets/catalogo/079.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-21','Referencia #21','Cruces','Producto del Catálogo Fúnebre 2026.',600,'','/assets/catalogo/080.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-22','Referencia #22','Cruces','Producto del Catálogo Fúnebre 2026.',650,'','/assets/catalogo/081.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-23','Referencia #23','Cruces','Producto del Catálogo Fúnebre 2026.',800,'','/assets/catalogo/082.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-24','Referencia #24','Cruces','Producto del Catálogo Fúnebre 2026.',850,'','/assets/catalogo/083.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-25','Referencia #25','Cruces','Producto del Catálogo Fúnebre 2026.',700,'','/assets/catalogo/084.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-26','Referencia #26','Cruces','Producto del Catálogo Fúnebre 2026.',950,'','/assets/catalogo/085.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-27','Referencia #27','Cruces','Producto del Catálogo Fúnebre 2026.',900,'La ficha indica seis arreglos de $150 MXN cada uno.','/assets/catalogo/086.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-28','Referencia #28','Cruces','Producto del Catálogo Fúnebre 2026.',1000,'','/assets/catalogo/087.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-29','Referencia #29','Cruces','Producto del Catálogo Fúnebre 2026.',1950,'','/assets/catalogo/088.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-30','Referencia #30','Cruces','Producto del Catálogo Fúnebre 2026.',1400,'','/assets/catalogo/089.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-31','Referencia #31','Cruces','Producto del Catálogo Fúnebre 2026.',900,'','/assets/catalogo/090.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-32','Referencia #32','Pie de caja','Producto del Catálogo Fúnebre 2026.',450,'','/assets/catalogo/091.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-33','Referencia #33','Pie de caja','Producto del Catálogo Fúnebre 2026.',550,'','/assets/catalogo/092.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-34','Referencia #34','Pie de caja','Producto del Catálogo Fúnebre 2026.',600,'','/assets/catalogo/093.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-35','Referencia #35','Pie de caja','Producto del Catálogo Fúnebre 2026.',650,'','/assets/catalogo/094.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-36','Referencia #36','Pie de caja','Producto del Catálogo Fúnebre 2026.',750,'','/assets/catalogo/095.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-37','Referencia #37','Pie de caja','Producto del Catálogo Fúnebre 2026.',850,'','/assets/catalogo/096.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-38','Referencia #38','Pie de caja','Producto del Catálogo Fúnebre 2026.',650,'','/assets/catalogo/097.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-39','Referencia #39','Pie de caja','Producto del Catálogo Fúnebre 2026.',600,'','/assets/catalogo/098.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-40','Referencia #40','Pie de caja','Producto del Catálogo Fúnebre 2026.',900,'','/assets/catalogo/099.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-41','Referencia #41','Pie de caja','Producto del Catálogo Fúnebre 2026.',1100,'','/assets/catalogo/100.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-44','Referencia #44','Cubre caja','Producto del Catálogo Fúnebre 2026.',380,'','/assets/catalogo/101.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-45','Referencia #45','Cubre caja','Producto del Catálogo Fúnebre 2026.',450,'','/assets/catalogo/102.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-46','Referencia #46','Cubre caja','Producto del Catálogo Fúnebre 2026.',650,'','/assets/catalogo/103.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-47','Referencia #47','Cubre caja','Producto del Catálogo Fúnebre 2026.',600,'','/assets/catalogo/104.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-48','Referencia #48','Caballetes','Producto del Catálogo Fúnebre 2026.',350,'','/assets/catalogo/105.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-49','Referencia #49','Caballetes','Producto del Catálogo Fúnebre 2026.',500,'','/assets/catalogo/106.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-50','Referencia #50','Caballetes','Producto del Catálogo Fúnebre 2026.',750,'','/assets/catalogo/107.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-51','Referencia #51','Caballetes','Producto del Catálogo Fúnebre 2026.',550,'','/assets/catalogo/108.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-52','Referencia #52','Caballetes','Producto del Catálogo Fúnebre 2026.',750,'','/assets/catalogo/109.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-53','Referencia #53','Caballetes','Producto del Catálogo Fúnebre 2026.',850,'','/assets/catalogo/110.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-54','Referencia #54','Caballetes','Producto del Catálogo Fúnebre 2026.',550,'','/assets/catalogo/111.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;
INSERT INTO public.products (catalog_key,name,category,description,price,price_note,image_url,stock,is_active) VALUES ('funebre-55','Referencia #55','Caballetes','Producto del Catálogo Fúnebre 2026.',850,'','/assets/catalogo/112.jpg',0,true) ON CONFLICT (catalog_key) DO NOTHING;

-- Add administrator after configuring Google Auth. Repeat for each approved email:
-- INSERT INTO public.admins (email) VALUES (lower('correo-admin@gmail.com'))
-- ON CONFLICT DO NOTHING;
