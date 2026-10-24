---------------------------------------------------------------------------
-- 12_login_seguro.sql  |  Proyecto 2: Licitacion IMAX
-- Contrasenas reales para el login de la interfaz web.
-- Correr como postgres, DESPUES de 11_app_gui.sql. Se puede repetir sin problema.
--
-- Que hace:
--   1. Activa la extension pgcrypto (cifrado bcrypt de contrasenas).
--   2. Reemplaza el password_hash de prueba ('hash_demo') por un hash bcrypt.
--      Cada usuario demo queda con la contrasena:  <rol>123
--        cliente123, taquillero123, operador_sala123, contador123, administrador123
--      (el correo sigue siendo cliente1@demo.imax, taquillero1@demo.imax, etc.)
--   3. Cambia fn_login_usuario para que pida correo Y contrasena. La funcion
--      nunca devuelve el hash.
--   4. Agrega el nombre de la promocion aplicada a v_compra_boletos (para el
--      desglose del pago).
---------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Un hash por rol (la contrasena es <nombre del rol>123). Solo toca a los
-- usuarios que aun tienen el hash de prueba.
UPDATE usuario u
   SET password_hash = h.hash
  FROM (SELECT r.rol_id,
               crypt(r.nombre || '123', gen_salt('bf', 8)) AS hash
        FROM rol r) h
 WHERE h.rol_id = u.rol_id
   AND u.password_hash = 'hash_demo';

-- La version vieja entraba solo con el correo: se elimina.
DROP FUNCTION IF EXISTS fn_login_usuario(VARCHAR);

CREATE OR REPLACE FUNCTION fn_login_usuario(p_correo VARCHAR, p_clave VARCHAR)
RETURNS TABLE (usuario_id BIGINT, nombre VARCHAR, apellido VARCHAR, rol VARCHAR)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.usuario_id, u.nombre, u.apellido, r.nombre
    FROM usuario u
    JOIN rol r ON r.rol_id = u.rol_id
    WHERE lower(u.correo) = lower(p_correo)
      AND u.activo
      AND CASE WHEN u.password_hash LIKE '$2%'
               THEN u.password_hash = crypt(p_clave, u.password_hash)
               ELSE FALSE
          END;
$$;

REVOKE ALL ON FUNCTION fn_login_usuario(VARCHAR, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_login_usuario(VARCHAR, VARCHAR) TO app_imax;

-- Boletos de una compra, ahora con la promocion aplicada (columna nueva al final)
CREATE OR REPLACE VIEW v_compra_boletos AS
SELECT c.compra_id,
       c.usuario_id,
       c.vendedor_id,
       c.estado    AS estado_compra,
       b.boleto_id,
       f.funcion_id,
       p.titulo,
       ci.nombre   AS cine,
       s.nombre    AS sala,
       f.inicio,
       z.nombre    AS zona,
       a.fila,
       a.numero,
       te.nombre   AS tipo_entrada,
       b.precio_final,
       b.estado,
       b.codigo_qr,
       pr.nombre   AS promocion
FROM compra c
JOIN boleto b        ON b.compra_id = c.compra_id
JOIN funcion f       ON f.funcion_id = b.funcion_id
JOIN pelicula p      ON p.pelicula_id = f.pelicula_id
JOIN sala s          ON s.sala_id = f.sala_id
JOIN cine ci         ON ci.cine_id = s.cine_id
JOIN asiento a       ON a.asiento_id = b.asiento_id
JOIN zona z          ON z.zona_id = a.zona_id
JOIN tipo_entrada te ON te.tipo_entrada_id = b.tipo_entrada_id
LEFT JOIN promocion pr ON pr.promocion_id = b.promocion_id;

-- Prueba rapida (opcional):
--   SELECT * FROM fn_login_usuario('cliente1@demo.imax', 'cliente123');   -- 1 fila
--   SELECT * FROM fn_login_usuario('cliente1@demo.imax', 'otra');         -- 0 filas
