-- pruebas/rbac_demo.sql | Demostracion de restriccion de roles (RN-17)
-- Se corre como superusuario (postgres) despues de 07_roles_rbac.sql.
-- Cada bloque cambia de rol con SET ROLE y vuelve con RESET ROLE.
-- Las sentencias que dicen "debe fallar" tienen que dar "permission denied".
-- Pega el resultado de cada bloque como evidencia para la pauta de revision.

BEGIN;  -- todo se deshace al final con ROLLBACK, la base queda igual

CREATE OR REPLACE FUNCTION pg_temp.intentar(q TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'PERMITIDO';
EXCEPTION WHEN OTHERS THEN
    RETURN 'BLOQUEADO: ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.intentar(TEXT) TO PUBLIC;

SELECT '=== CLIENTE';
SET ROLE rol_cliente;
SELECT 'ver cartelera'               AS intento, pg_temp.intentar('SELECT * FROM v_cartelera')                         AS resultado
UNION ALL SELECT 'ver mapa de asientos',          pg_temp.intentar('SELECT * FROM v_mapa_asientos')
UNION ALL SELECT 'ver sus boletos',               pg_temp.intentar('SELECT * FROM v_mis_boletos')
UNION ALL SELECT 'ver tarifas (permitido, las necesita para comprar)', pg_temp.intentar('SELECT * FROM tarifa')
UNION ALL SELECT 'leer tabla usuario (debe fallar)', pg_temp.intentar('SELECT * FROM usuario')
UNION ALL SELECT 'modificar sala (debe fallar)',    pg_temp.intentar('UPDATE sala SET capacidad = 1')
UNION ALL SELECT 'modificar precio (debe fallar)',  pg_temp.intentar('UPDATE tarifa SET precio = 0')
UNION ALL SELECT 'ver bitacora admin (debe fallar)', pg_temp.intentar('SELECT * FROM admin_operacion_audit')
UNION ALL SELECT 'cambiar tarifa con fn (debe fallar)', pg_temp.intentar('SELECT fn_cambiar_tarifa(1,1,1,''x'')')
UNION ALL SELECT 'validar entrada (debe fallar)',   pg_temp.intentar('SELECT fn_validar_entrada(gen_random_uuid(),1,''P1'')');
RESET ROLE;

SELECT '=== TAQUILLERO';
SET ROLE rol_taquillero;
SELECT 'ver su corte de caja'        AS intento, pg_temp.intentar('SELECT * FROM v_corte_caja')                         AS resultado
UNION ALL SELECT 'crear sala (debe fallar)',        pg_temp.intentar('INSERT INTO sala(cine_id,nombre,capacidad) VALUES (1,''X'',10)')
UNION ALL SELECT 'modificar precios (debe fallar)', pg_temp.intentar('UPDATE tarifa SET precio = 0')
UNION ALL SELECT 'modificar configuracion (debe fallar)', pg_temp.intentar('UPDATE configuracion SET valor = ''99''')
UNION ALL SELECT 'ver bitacora admin (debe fallar)', pg_temp.intentar('SELECT * FROM admin_operacion_audit')
UNION ALL SELECT 'otorgar cortesia (debe fallar)',  pg_temp.intentar('SELECT fn_otorgar_cortesia(2,1,1,3,1,''x'')')
UNION ALL SELECT 'validar entrada (debe fallar)',   pg_temp.intentar('SELECT fn_validar_entrada(gen_random_uuid(),1,''P1'')');
RESET ROLE;

SELECT '=== OPERADOR DE SALA';
SET ROLE rol_operador_sala;
SELECT 'validar entrada'             AS intento, pg_temp.intentar('SELECT fn_validar_entrada(gen_random_uuid(),1,''Puerta 1'')') AS resultado
UNION ALL SELECT 'ver cartelera',                   pg_temp.intentar('SELECT * FROM v_cartelera')
UNION ALL SELECT 'vender boletos (debe fallar)',    pg_temp.intentar('SELECT fn_pagar_compra(1,1::smallint,true)')
UNION ALL SELECT 'ver pagos (debe fallar)',         pg_temp.intentar('SELECT * FROM pago');
RESET ROLE;

SELECT '=== CONTADOR';
SET ROLE rol_contador;
SELECT 'ver pagos y compras'         AS intento, pg_temp.intentar('SELECT * FROM pago') AS resultado
UNION ALL SELECT 'ver ingresos por funcion',        pg_temp.intentar('SELECT * FROM v_ocupacion_funcion')
UNION ALL SELECT 'modificar un pago (debe fallar)', pg_temp.intentar('UPDATE pago SET monto = 0')
UNION ALL SELECT 'ver usuarios (debe fallar)',      pg_temp.intentar('SELECT * FROM usuario')
UNION ALL SELECT 'crear funcion (debe fallar)',     pg_temp.intentar('INSERT INTO funcion(pelicula_id,sala_id,inicio,fin) VALUES (1,1,now()+interval ''9 days'',now()+interval ''9 days 2 hours'')')
UNION ALL SELECT 'pagar una compra (debe fallar)',  pg_temp.intentar('SELECT fn_pagar_compra(1,1::smallint,true)');
RESET ROLE;

SELECT '=== ADMINISTRADOR';
SET ROLE rol_administrador;
SELECT 'ver bitacora admin'          AS intento, pg_temp.intentar('SELECT * FROM admin_operacion_audit') AS resultado
UNION ALL SELECT 'ver usuarios sin hash',           pg_temp.intentar('SELECT usuario_id, correo, rol_id FROM usuario')
UNION ALL SELECT 'ver hash de contrasena (debe fallar)', pg_temp.intentar('SELECT password_hash FROM usuario')
UNION ALL SELECT 'crear pelicula',                  pg_temp.intentar('INSERT INTO pelicula(titulo,sinopsis,duracion_min,clasificacion_id) VALUES (''Demo'',''Demo'',90,1)')
UNION ALL SELECT 'crear funcion',                   pg_temp.intentar('INSERT INTO funcion(pelicula_id,sala_id,inicio,fin) VALUES (1,3,now()+interval ''9 days'',now()+interval ''9 days 2 hours'')')
UNION ALL SELECT 'UPDATE directo de precio (debe fallar, se usa fn_cambiar_tarifa)', pg_temp.intentar('UPDATE tarifa SET precio = 1')
UNION ALL SELECT 'cambiar precio con fn_cambiar_tarifa', pg_temp.intentar('SELECT fn_cambiar_tarifa(2021,(SELECT min(tarifa_id) FROM tarifa),15,''demo de roles'')')
UNION ALL SELECT 'cambiar regla de configuracion',  pg_temp.intentar('SELECT fn_cambiar_configuracion(2021,''max_asientos_por_compra'',''6'',''demo de roles'')')
UNION ALL SELECT 'borrar bitacora (debe fallar)',   pg_temp.intentar('DELETE FROM admin_operacion_audit')
UNION ALL SELECT 'vender boletos (debe fallar)',    pg_temp.intentar('SELECT fn_pagar_compra(1,1::smallint,true)');
RESET ROLE;

ROLLBACK;

