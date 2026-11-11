-- Florería Muñiz: habilita costo unitario y utilidad bruta histórica.
-- Ejecutar una sola vez en Supabase > SQL Editor.
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS cost_price numeric(10,2)
  CHECK (cost_price IS NULL OR cost_price >= 0);

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot numeric(10,2)
  CHECK (unit_cost_snapshot IS NULL OR unit_cost_snapshot >= 0);

-- Las ventas nuevas guardan una copia del costo del producto para conservar
-- el margen histórico aunque el costo del catálogo cambie después.
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
    SELECT id,name,price,cost_price INTO product_row
    FROM public.products WHERE id=item.product_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product not found'; END IF;

    INSERT INTO public.order_items(
      order_id,product_id,product_name_snapshot,unit_price_snapshot,
      unit_cost_snapshot,quantity
    ) VALUES (
      new_order_id,product_row.id,product_row.name,product_row.price,
      product_row.cost_price,item.quantity
    );
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

NOTIFY pgrst, 'reload schema';
