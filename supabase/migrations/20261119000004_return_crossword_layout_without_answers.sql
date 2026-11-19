CREATE OR REPLACE FUNCTION public.iniciar_examen(p_examen_id uuid)
 RETURNS TABLE(id uuid, orden integer, tipo text, enunciado text, opciones jsonb, puntos numeric, config_jsonb jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tema_id text;
  v_activo boolean;
  v_reeval boolean;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión.';
  end if;

  select e.tema_id, e.activo, e.es_reevaluacion
    into v_tema_id, v_activo, v_reeval
  from public.examenes e where e.id = p_examen_id;

  if v_tema_id is null then raise exception 'El examen no existe.'; end if;
  if not v_activo then raise exception 'Este examen ya no está disponible.'; end if;

  if coalesce(v_reeval, false) then
    if not exists (
      select 1 from public.examen_destinatarios d
      where d.examen_id = p_examen_id and d.user_id = auth.uid()
    ) then
      raise exception 'NO_ASIGNADO: esta reevaluación no está asignada a tu cuenta.';
    end if;
  elsif not public._tema_completado_por_usuario(v_tema_id, auth.uid()) then
    raise exception 'INCOMPLETO: primero debes terminar todos los videos de este tema.';
  end if;

  return query
  select
    ep.id, ep.orden, ep.tipo, ep.enunciado, ep.opciones, ep.puntos,
    case
      when ep.tipo = 'sopa_letras' then
        jsonb_build_object(
          'grid', coalesce(ep.config_jsonb->'grid','[]'::jsonb),
          'words', coalesce(
            (select jsonb_agg(to_jsonb(w->>'word') order by ord)
             from jsonb_array_elements(coalesce(ep.config_jsonb->'words','[]'::jsonb))
                  with ordinality a(w,ord)),
            '[]'::jsonb
          )
        )
      when ep.tipo = 'crucigrama' then
        jsonb_build_object(
          'grid', coalesce(ep.config_jsonb->'grid','[]'::jsonb),
          'entries', coalesce(
            (select jsonb_agg(jsonb_build_object(
              'id', e->>'id', 'clue', e->>'clue',
              'length', coalesce((e->>'length')::int, length(e->>'answer')),
              'row', (e->>'row')::int, 'col', (e->>'col')::int,
              'direction', e->>'direction', 'number', (e->>'number')::int
            ) order by ord)
             from jsonb_array_elements(coalesce(ep.config_jsonb->'entries','[]'::jsonb))
                  with ordinality a(e,ord)),
            '[]'::jsonb
          )
        )
      when ep.tipo = 'relacionar' then
        jsonb_build_object(
          'left', coalesce(
            (select jsonb_agg(to_jsonb(x->>'left') order by ord)
             from jsonb_array_elements(coalesce(ep.config_jsonb->'pairs','[]'::jsonb))
                  with ordinality a(x,ord)),
            '[]'::jsonb
          ),
          'right', coalesce(
            (select jsonb_agg(to_jsonb(x->>'right') order by random())
             from jsonb_array_elements(coalesce(ep.config_jsonb->'pairs','[]'::jsonb))
                  with ordinality a(x,ord)),
            '[]'::jsonb
          )
        )
      else '{}'::jsonb
    end
  from public.examen_preguntas ep
  where ep.examen_id = p_examen_id
  order by ep.orden asc, ep.created_at asc;
end;
$function$
;