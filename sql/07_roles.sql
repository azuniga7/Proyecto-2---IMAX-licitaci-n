-- 07_roles_rbac.sql  |  Proyecto 2: Licitacion IMAX
-- Control de acceso por roles (RN-17) con privilegio minimo, segun la
-- matriz de roles del enunciado. Se ejecuta despues del 06.
-- Se puede volver a correr sin problema.

DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['rol_cliente', 'rol_taquillero', 'rol_operador_sala',
                             'rol_contador', 'rol_administrador']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;
 

-- 2. Funcion nueva: cambiar una regla de configuracion (RN-04, RN-05, RN-16,
-- RN-19, cargo por servicio). Es una configuracion critica, por eso solo se
-- cambia con esta funcion, que exige administrador, motivo y deja bitacora (RN-20).
-- Si la clave no existe, la crea (por ejemplo cargo_servicio_por_boleto).

CREATE OR REPLACE FUNCTION fn_cambiar_configuracion(
    p_admin  BIGINT,
    p_clave  VARCHAR,
    p_valor  VARCHAR,
    p_motivo TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol      SMALLINT;
    v_anterior VARCHAR(100);
BEGIN
    v_rol := fn_exigir_admin(p_admin);
 
    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'El motivo es obligatorio';
    END IF;
    -- fn_config_int convierte todos los valores a entero
    IF p_valor IS NULL OR p_valor !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'El valor debe ser un numero entero mayor o igual a cero';
    END IF;
 
    SELECT valor INTO v_anterior FROM configuracion WHERE clave = p_clave FOR UPDATE;
 
    INSERT INTO configuracion (clave, valor)
    VALUES (p_clave, p_valor)
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;
 
    PERFORM fn_registrar_auditoria_admin(
        p_admin, v_rol, 'cambio_configuracion', 'configuracion', p_clave,
        jsonb_build_object('valor_anterior', v_anterior,
                           'valor_nuevo', p_valor,
                           'motivo', p_motivo));
 
    RETURN 'CONFIGURACION ACTUALIZADA: ' || p_clave || ' = ' || p_valor;
END;
$$;
 

DO $$
DECLARE
    f RECORD;
BEGIN
    FOR f IN
        SELECT p.oid::regprocedure AS firma
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname LIKE 'fn\_%'
          AND p.prokind = 'f'
    LOOP
        EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = public, pg_temp', f.firma);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    END LOOP;
END $$;
 
-- Las funciones que se creen despues tampoco quedan abiertas a todos
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
 

-- 4. Quitar acceso general a tablas, vistas y secuencias

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
 
GRANT USAGE ON SCHEMA public
    TO rol_cliente, rol_taquillero, rol_operador_sala, rol_contador, rol_administrador;
 

-- 5. Permisos por rol 

 
-- Catalogo y cartelera: lectura para todos los roles
GRANT SELECT ON v_cartelera, v_mapa_asientos
    TO rol_cliente, rol_taquillero, rol_operador_sala, rol_contador, rol_administrador;
 
-- CLIENTE: compra online y ve sus propios boletos con QR
GRANT SELECT  ON v_mis_boletos TO rol_cliente;
GRANT EXECUTE ON FUNCTION fn_bloquear_asiento(BIGINT, BIGINT, BIGINT) TO rol_cliente;
GRANT EXECUTE ON FUNCTION fn_crear_compra(BIGINT, BIGINT, BIGINT[], INT[], BIGINT) TO rol_cliente;
GRANT EXECUTE ON FUNCTION fn_pagar_compra(BIGINT, SMALLINT, BOOLEAN) TO rol_cliente;
-- La matriz no le da al cliente la anulacion de entradas. Si el equipo quiere
-- que el cliente pida su propio reembolso (RN-19), basta con descomentar:
 
-- TAQUILLERO: venta presencial, lectura de boletos y su propio corte de caja
GRANT SELECT  ON v_mis_boletos, v_corte_caja TO rol_taquillero;
GRANT EXECUTE ON FUNCTION fn_bloquear_asiento(BIGINT, BIGINT, BIGINT) TO rol_taquillero;
GRANT EXECUTE ON FUNCTION fn_crear_compra(BIGINT, BIGINT, BIGINT[], INT[], BIGINT) TO rol_taquillero;
GRANT EXECUTE ON FUNCTION fn_pagar_compra(BIGINT, SMALLINT, BOOLEAN) TO rol_taquillero;
GRANT EXECUTE ON FUNCTION fn_reembolsar_boleto(BIGINT, BIGINT, TEXT, BOOLEAN) TO rol_taquillero;
 
-- OPERADOR DE SALA: solo valida entradas en la puerta
GRANT EXECUTE ON FUNCTION fn_validar_entrada(UUID, BIGINT, VARCHAR) TO rol_operador_sala;
 
-- CONTADOR: reportes y finanzas (conciliacion, ingresos). No ve usuarios ni
-- bitacoras de acceso, y no puede modificar nada.
GRANT SELECT ON compra, pago, reembolso, metodo_pago, transaccion_log,
                v_ocupacion_funcion, v_ventas_diarias
    TO rol_contador;
 
GRANT SELECT ON ALL TABLES IN SCHEMA public TO rol_administrador;
REVOKE SELECT ON usuario FROM rol_administrador;
GRANT  SELECT (usuario_id, rol_id, nombre, apellido, correo, activo, fecha_registro)
    ON usuario TO rol_administrador;
GRANT  UPDATE (rol_id, activo) ON usuario TO rol_administrador;
 
GRANT INSERT, UPDATE, DELETE ON
    pelicula, pelicula_genero, genero, clasificacion,
    cine, sala, zona, asiento, funcion,
    promocion, tipo_entrada, metodo_pago
    TO rol_administrador;
 

GRANT INSERT ON tarifa TO rol_administrador;
 
GRANT EXECUTE ON FUNCTION fn_cambiar_asiento(BIGINT, BIGINT, BIGINT, TEXT) TO rol_administrador;
GRANT EXECUTE ON FUNCTION fn_otorgar_cortesia(BIGINT, BIGINT, BIGINT, BIGINT, INT, TEXT) TO rol_administrador;
GRANT EXECUTE ON FUNCTION fn_cambiar_tarifa(BIGINT, BIGINT, NUMERIC, TEXT) TO rol_administrador;
GRANT EXECUTE ON FUNCTION fn_cambiar_configuracion(BIGINT, VARCHAR, VARCHAR, TEXT) TO rol_administrador;
GRANT EXECUTE ON FUNCTION fn_reembolsar_boleto(BIGINT, BIGINT, TEXT, BOOLEAN) TO rol_administrador;