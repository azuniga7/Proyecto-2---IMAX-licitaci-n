----------------------------------------------------------------------
-- 07b_ajustes_rbac.sql  |  Proyecto 2: Licitación IMAX
-- Ajustes a 07_roles_rbac.sql. Se ejecuta DESPUÉS del 07.
-- Se puede volver a ejecutar sin problema.
----------------------------------------------------------------------

-- La pantalla de pago necesita mostrar precios, tipos de entrada,
-- promociones y métodos de pago. Sin este permiso el cliente y el taquillero
-- no podrían leer esas tablas.
GRANT SELECT ON tarifa, tipo_entrada, promocion, metodo_pago
    TO rol_cliente, rol_taquillero;
