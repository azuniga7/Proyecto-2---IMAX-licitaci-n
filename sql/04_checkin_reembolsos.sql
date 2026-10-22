-- ------------------------------------------------------------------------
-- 04_checkin_reembolsos.sql  |  Proyecto 2: Licitacion IMAX
-- ------------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- FUNCION: validar una entrada en la puerta (escaneo del QR)
--   p_codigo_qr : codigo leido en el totem
--   p_funcion   : funcion que se esta atendiendo en esa puerta
--   p_puerta    : nombre de la puerta o del dispositivo de lectura
-- Siempre deja un registro en acceso_puerta_log (exitoso o rechazado).
-- Devuelve un texto con el resultado. No lanza excepciones a proposito:
-- si lo hiciera, el registro del log se desharia junto con la transaccion.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validar_entrada(
    p_codigo_qr UUID,
    p_funcion   BIGINT,
    p_puerta    VARCHAR
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_boleto  boleto%ROWTYPE;
    v_inicio  TIMESTAMPTZ;
    v_antes   INT := COALESCE(fn_config_int('tolerancia_antes_min'), 30);
    v_despues INT := COALESCE(fn_config_int('tolerancia_despues_min'), 15);
BEGIN
    -- Se bloquea la fila del boleto: si dos totems escanean el mismo QR a la vez,
    -- el segundo espera y luego lo encuentra ya 'usado' (RN-14).
    SELECT * INTO v_boleto
    FROM boleto
    WHERE codigo_qr = p_codigo_qr
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado)
        VALUES (NULL, p_codigo_qr, p_puerta, 'rechazado_inexistente');
        RETURN 'RECHAZADO: el codigo QR no existe';
    END IF;

    -- Boleto anulado o reembolsado (se registra como 'rechazado_inexistente')
    IF v_boleto.estado NOT IN ('valido', 'usado') THEN
        INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado)
        VALUES (v_boleto.boleto_id, p_codigo_qr, p_puerta, 'rechazado_inexistente');
        RETURN 'RECHAZADO: la entrada no es valida (estado: ' || v_boleto.estado || ')';
    END IF;

    -- RN-14: una entrada solo se puede usar una vez
    IF v_boleto.estado = 'usado' THEN
        INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado)
        VALUES (v_boleto.boleto_id, p_codigo_qr, p_puerta, 'rechazado_duplicado');
        RETURN 'RECHAZADO: Entrada ya utilizada';
    END IF;

    -- RN-15: la entrada debe ser de la funcion que se atiende
    IF v_boleto.funcion_id <> p_funcion THEN
        INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado)
        VALUES (v_boleto.boleto_id, p_codigo_qr, p_puerta, 'rechazado_funcion');
        RETURN 'RECHAZADO: la entrada corresponde a otra funcion';
    END IF;

    -- RN-16: ventana de ingreso (por defecto 30 min antes hasta 15 min despues del inicio)
    SELECT inicio INTO v_inicio FROM funcion WHERE funcion_id = v_boleto.funcion_id;

    IF now() < v_inicio - make_interval(mins => v_antes) THEN
        INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado)
        VALUES (v_boleto.boleto_id, p_codigo_qr, p_puerta, 'rechazado_horario');
        RETURN 'RECHAZADO: todavia es muy temprano para ingresar';
    END IF;

    IF now() > v_inicio + make_interval(mins => v_despues) THEN
        INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado)
        VALUES (v_boleto.boleto_id, p_codigo_qr, p_puerta, 'rechazado_horario');
        RETURN 'RECHAZADO: fuera del tiempo de tolerancia de ingreso';
    END IF;

    -- Todo en orden: se marca como usado y se registra el acceso
    UPDATE boleto
       SET estado = 'usado',
           fecha_uso = now()
     WHERE boleto_id = v_boleto.boleto_id;

    INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado)
    VALUES (v_boleto.boleto_id, p_codigo_qr, p_puerta, 'exitoso');

    RETURN 'ACCESO PERMITIDO';
END;
$$;

-- ---------------------------------------------------------------------
-- FUNCION: reembolsar un boleto (RN-19)
--   p_boleto  : boleto a reembolsar
--   p_usuario : quien realiza la operacion
--   p_motivo  : motivo (obligatorio)
--   p_forzado : TRUE salta el limite de tiempo; solo lo puede hacer un administrador
-- Efectos: boleto anulado, asiento liberado, reembolso registrado y,
-- si es forzado, bitacora administrativa (RN-20).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_reembolsar_boleto(
    p_boleto  BIGINT,
    p_usuario BIGINT,
    p_motivo  TEXT,
    p_forzado BOOLEAN DEFAULT FALSE
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_boleto BOLETO%ROWTYPE;
    v_inicio TIMESTAMPTZ;
    v_horas  INT := COALESCE(fn_config_int('horas_limite_reembolso'), 2);
    v_rol    VARCHAR;
    v_rol_id SMALLINT;
    v_monto  NUMERIC(10,2);
BEGIN
    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'Debe indicar el motivo del reembolso';
    END IF;

    SELECT u.rol_id, r.nombre INTO v_rol_id, v_rol
    FROM usuario u
    JOIN rol r ON r.rol_id = u.rol_id
    WHERE u.usuario_id = p_usuario;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario % no existe', p_usuario;
    END IF;

    IF p_forzado AND v_rol <> 'administrador' THEN
        RAISE EXCEPTION 'Solo un administrador puede forzar un reembolso';
    END IF;

    SELECT * INTO v_boleto FROM boleto WHERE boleto_id = p_boleto FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boleto % no existe', p_boleto;
    END IF;

    IF v_boleto.estado <> 'valido' THEN
        RETURN 'RECHAZADO: solo se pueden reembolsar boletos validos (estado actual: '
               || v_boleto.estado || ')';
    END IF;

    -- Un reembolso normal lo pide el comprador, un taquillero o un administrador
    IF NOT p_forzado
       AND v_rol NOT IN ('taquillero', 'administrador')
       AND NOT EXISTS (SELECT 1 FROM compra c
                       WHERE c.compra_id = v_boleto.compra_id
                         AND c.usuario_id = p_usuario) THEN
        RAISE EXCEPTION 'No tiene permiso para reembolsar este boleto';
    END IF;

    -- RN-19: solo hasta X horas antes de la funcion (salvo reembolso forzado)
    SELECT inicio INTO v_inicio FROM funcion WHERE funcion_id = v_boleto.funcion_id;
    IF NOT p_forzado AND now() > v_inicio - make_interval(hours => v_horas) THEN
        RETURN 'RECHAZADO: el reembolso solo se permite hasta ' || v_horas
               || ' horas antes de la funcion';
    END IF;

    v_monto := v_boleto.precio_final;

    UPDATE boleto SET estado = 'anulado' WHERE boleto_id = p_boleto;

    -- El asiento vuelve a estar disponible para la venta
    UPDATE funcion_asiento
       SET estado = 'disponible',
           bloqueado_por = NULL,
           bloqueado_hasta = NULL
     WHERE funcion_id = v_boleto.funcion_id
       AND asiento_id = v_boleto.asiento_id
       AND estado = 'vendido';

    INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento)
    VALUES (v_boleto.funcion_id, v_boleto.asiento_id, p_usuario, 'liberado_anulacion');

    -- Un boleto gratis (2x1) no tiene dinero que devolver
    IF v_monto > 0 THEN
        INSERT INTO reembolso (boleto_id, monto, motivo, forzado, autorizado_por)
        VALUES (p_boleto, v_monto, p_motivo, p_forzado, p_usuario);
    END IF;

    INSERT INTO transaccion_log (compra_id, evento, monto, resultado)
    VALUES (v_boleto.compra_id, 'reembolso', v_monto,
            CASE WHEN p_forzado THEN 'forzado' ELSE 'aprobado' END);

    -- RN-20: toda operacion manual de un administrador queda en la bitacora
    IF p_forzado THEN
        INSERT INTO admin_operacion_audit
            (usuario_id, rol_id, ip, accion, tabla_afectada, registro_id, detalle)
        VALUES
            (p_usuario, v_rol_id, inet_client_addr(), 'reembolso_forzado', 'boleto',
             p_boleto::TEXT,
             jsonb_build_object('monto', v_monto, 'motivo', p_motivo));
    END IF;

    RETURN 'REEMBOLSADO: se devolvieron ' || v_monto || ' y el asiento quedo disponible';
END;
$$;
