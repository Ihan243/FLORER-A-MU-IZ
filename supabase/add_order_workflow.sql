-- Florería Muñiz: agenda y flujo de preparación de pedidos.
-- Ejecutar una vez en Supabase Dashboard > SQL Editor.
BEGIN;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS fulfillment_status text NOT NULL DEFAULT 'pending';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS scheduled_date date;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS delivery_window varchar(60);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS order_notes text;

ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_fulfillment_status_check;
ALTER TABLE public.orders ADD CONSTRAINT orders_fulfillment_status_check
  CHECK (fulfillment_status IN ('pending','confirmed','preparing','ready','delivered','cancelled'));

CREATE INDEX IF NOT EXISTS orders_schedule_status_idx
  ON public.orders(scheduled_date, fulfillment_status);

CREATE OR REPLACE FUNCTION public.create_admin_order_v2(
  p_customer_name text,
  p_customer_phone text,
  p_payment_status public.order_status,
  p_fulfillment_status text,
  p_scheduled_date date,
  p_delivery_window text,
  p_order_notes text,
  p_items jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
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
  IF p_fulfillment_status IS NULL OR p_fulfillment_status NOT IN ('pending','confirmed','preparing','ready','delivered','cancelled') THEN
    RAISE EXCEPTION 'Invalid fulfillment status';
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Order items must be a JSON array';
  END IF;
  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'At least one order item is required';
  END IF;

  INSERT INTO public.orders(customer_name,customer_phone,status,total_amount,fulfillment_status,scheduled_date,delivery_window,order_notes)
  VALUES(trim(p_customer_name),nullif(trim(coalesce(p_customer_phone,'')),''),p_payment_status,0,
         p_fulfillment_status,p_scheduled_date,nullif(trim(coalesce(p_delivery_window,'')),''),
         nullif(trim(coalesce(p_order_notes,'')),''))
  RETURNING id INTO new_order_id;

  FOR item IN
    SELECT * FROM jsonb_to_recordset(p_items) AS x(product_id uuid, quantity integer)
  LOOP
    IF item.product_id IS NULL OR item.quantity IS NULL OR item.quantity < 1 THEN
      RAISE EXCEPTION 'Each item needs a product and positive quantity';
    END IF;
    SELECT id,name,price INTO product_row
    FROM public.products WHERE id=item.product_id AND is_active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product not found or inactive'; END IF;
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

REVOKE ALL ON FUNCTION public.create_admin_order_v2(text,text,public.order_status,text,date,text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_admin_order_v2(text,text,public.order_status,text,date,text,text,jsonb) TO authenticated;

COMMIT;
