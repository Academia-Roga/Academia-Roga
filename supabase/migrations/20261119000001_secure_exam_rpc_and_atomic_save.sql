-- Permisos acotados para RPC de exámenes y guardado atómico del constructor.

revoke all on function public._normalizar_texto(text) from public, anon, authenticated;

alter function public._normalizar_texto(text) set search_path='';

revoke all on function public._tema_completado_por_usuario(text,uuid) from public, anon, authenticated;

alter function public._tema_completado_por_usuario(text,uuid) set search_path='';

revoke all on function public.handle_new_user() from public, anon, authenticated;

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
          'entries', coalesce(
            (select jsonb_agg(jsonb_build_object(
              'id', e->>'id', 'clue', e->>'clue',
              'length', coalesce((e->>'length')::int, length(e->>'answer'))
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

CREATE OR REPLACE FUNCTION public.calificar_examen(p_examen_id uuid, p_respuestas jsonb)
 RETURNS TABLE(calificacion numeric, aprobado boolean, folio text, examen_titulo text, minima_aprobatoria numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid; v_user_email text; v_tema_id text; v_titulo text;
  v_min numeric; v_activo boolean; v_reeval boolean; v_p record;
  v_r jsonb; v_answer jsonb; v_text text; v_idx integer;
  v_total numeric:=0; v_score numeric:=0; v_pts numeric;
  v_grade numeric; v_pass boolean; v_attempt uuid; v_folio text;
  v_accepted text; v_correct integer; v_count integer; v_item jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  v_user_id:=auth.uid();
  select email into v_user_email from auth.users where id=v_user_id;
  select tema_id,titulo,calificacion_minima,activo,es_reevaluacion
    into v_tema_id,v_titulo,v_min,v_activo,v_reeval
    from public.examenes where id=p_examen_id;
  if v_tema_id is null then raise exception 'El examen no existe.'; end if;
  if not v_activo then raise exception 'Este examen ya no está disponible.'; end if;
  if coalesce(v_reeval,false) then
    if not exists(select 1 from public.examen_destinatarios where examen_id=p_examen_id and user_id=v_user_id) then
      raise exception 'NO_ASIGNADO: esta reevaluación no está asignada a tu cuenta.';
    end if;
  elsif not public._tema_completado_por_usuario(v_tema_id,v_user_id) then
    raise exception 'INCOMPLETO: primero debes terminar todos los videos de este tema.';
  end if;

  for v_p in select * from public.examen_preguntas where examen_id=p_examen_id order by orden asc loop
    v_pts:=coalesce(v_p.puntos,1); v_total:=v_total+v_pts;
    select elem into v_r from jsonb_array_elements(coalesce(p_respuestas,'[]'::jsonb)) elem
      where elem->>'pregunta_id'=v_p.id::text limit 1;
    v_answer:=coalesce(v_r->'respuesta','null'::jsonb);
    if v_p.tipo='opcion_multiple' then
      begin v_idx:=(v_r->>'respuesta')::integer; exception when others then v_idx:=null; end;
      if v_idx is not null and v_idx=v_p.respuesta_correcta_idx then v_score:=v_score+v_pts; end if;
    elsif v_p.tipo='abierta' then
      v_text:=public._normalizar_texto(v_r->>'respuesta');
      if v_r is not null then
        if v_p.respuestas_aceptadas is null or jsonb_array_length(v_p.respuestas_aceptadas)=0 then
          if v_text is not null and v_text<>'' then v_score:=v_score+v_pts; end if;
        else
          for v_accepted in select jsonb_array_elements_text(v_p.respuestas_aceptadas) loop
            if v_text like '%'||public._normalizar_texto(v_accepted)||'%' and public._normalizar_texto(v_accepted)<>'' then
              v_score:=v_score+v_pts; exit;
            end if;
          end loop;
        end if;
      end if;
    elsif v_p.tipo='relacionar' then
      v_count:=jsonb_array_length(coalesce(v_p.config_jsonb->'pairs','[]'::jsonb)); v_correct:=0;
      if v_count>0 and jsonb_typeof(v_answer)='object' then
        v_idx:=0;
        for v_item in select value from jsonb_array_elements(v_p.config_jsonb->'pairs') loop
          if public._normalizar_texto(v_answer->>v_idx::text)=public._normalizar_texto(v_item->>'right') then
            v_correct:=v_correct+1;
          end if;
          v_idx:=v_idx+1;
        end loop;
        v_score:=v_score+(v_pts*v_correct::numeric/v_count::numeric);
      end if;
    elsif v_p.tipo='sopa_letras' then
      v_count:=jsonb_array_length(coalesce(v_p.config_jsonb->'words','[]'::jsonb)); v_correct:=0;
      if v_count>0 and jsonb_typeof(v_answer)='array' then
        for v_item in select value from jsonb_array_elements(v_p.config_jsonb->'words') loop
          if exists(select 1 from jsonb_array_elements(v_answer) a
            where public._normalizar_texto(trim(both '"' from a::text))=public._normalizar_texto(v_item->>'word')) then
            v_correct:=v_correct+1;
          end if;
        end loop;
        v_score:=v_score+(v_pts*v_correct::numeric/v_count::numeric);
      end if;
    elsif v_p.tipo='crucigrama' then
      v_count:=jsonb_array_length(coalesce(v_p.config_jsonb->'entries','[]'::jsonb)); v_correct:=0;
      if v_count>0 and jsonb_typeof(v_answer)='object' then
        for v_item in select value from jsonb_array_elements(v_p.config_jsonb->'entries') loop
          if public._normalizar_texto(v_answer->>(v_item->>'id'))=public._normalizar_texto(v_item->>'answer') then
            v_correct:=v_correct+1;
          end if;
        end loop;
        v_score:=v_score+(v_pts*v_correct::numeric/v_count::numeric);
      end if;
    end if;
  end loop;

  if v_total=0 then raise exception 'Este examen no tiene preguntas configuradas.'; end if;
  v_grade:=round((v_score/v_total)*10,1); v_pass:=v_grade>=v_min;
  insert into public.examen_intentos(examen_id,user_id,user_email,tema_id,respuestas,calificacion,aprobado)
    values(p_examen_id,v_user_id,v_user_email,v_tema_id,coalesce(p_respuestas,'[]'::jsonb),v_grade,v_pass)
    returning id into v_attempt;
  v_folio:=null;
  if v_pass then
    v_folio:='ROGA-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(v_attempt::text,'-',''),1,6));
    insert into public.certificados(examen_id,intento_id,user_id,user_email,tema_id,tema_nombre,examen_titulo,calificacion,folio)
    values(p_examen_id,v_attempt,v_user_id,v_user_email,v_tema_id,v_tema_id,v_titulo,v_grade,v_folio)
    on conflict(user_id,examen_id) do update set
      calificacion=greatest(certificados.calificacion,excluded.calificacion),
      intento_id=case when excluded.calificacion>=certificados.calificacion then excluded.intento_id else certificados.intento_id end,
      emitido_at=case when excluded.calificacion>=certificados.calificacion then excluded.emitido_at else certificados.emitido_at end
    returning certificados.folio into v_folio;
  end if;
  return query select v_grade,v_pass,v_folio,v_titulo,v_min;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guardar_examen_modular(p_examen_id uuid, p_examen jsonb, p_preguntas jsonb, p_destinatarios uuid[] DEFAULT '{}'::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid; v_role text; v_id uuid; v_q jsonb; v_n integer:=0;
begin
 v_user:=auth.uid(); if v_user is null then raise exception 'Debes iniciar sesión.'; end if;
 select p.role into v_role from public.profiles p where p.id=v_user;
 if coalesce(v_role,'') not in ('admin','supervisor') then raise exception 'No tienes permisos para administrar exámenes.'; end if;
 if coalesce(trim(p_examen->>'titulo'),'')='' or coalesce(trim(p_examen->>'tema_id'),'')='' then raise exception 'El título y el tema son obligatorios.'; end if;
 if jsonb_typeof(coalesce(p_preguntas,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_preguntas,'[]'::jsonb))=0 then raise exception 'El examen debe incluir al menos una pregunta.'; end if;
 if coalesce((p_examen->>'calificacion_minima')::numeric,8.5)<0 or coalesce((p_examen->>'calificacion_minima')::numeric,8.5)>10 then raise exception 'La calificación mínima debe estar entre 0 y 10.'; end if;
 if coalesce((p_examen->>'es_reevaluacion')::boolean,false) and coalesce(cardinality(p_destinatarios),0)=0 then raise exception 'Selecciona al menos un operador para la reevaluación.'; end if;
 if p_examen_id is null then
  insert into public.examenes(tema_id,titulo,instrucciones,calificacion_minima,es_reevaluacion,creado_por)
  values(p_examen->>'tema_id',trim(p_examen->>'titulo'),nullif(trim(p_examen->>'instrucciones'),''),coalesce((p_examen->>'calificacion_minima')::numeric,8.5),coalesce((p_examen->>'es_reevaluacion')::boolean,false),nullif(p_examen->>'creado_por','')) returning id into v_id;
 else
  update public.examenes set tema_id=p_examen->>'tema_id',titulo=trim(p_examen->>'titulo'),instrucciones=nullif(trim(p_examen->>'instrucciones'),''),calificacion_minima=coalesce((p_examen->>'calificacion_minima')::numeric,8.5),es_reevaluacion=coalesce((p_examen->>'es_reevaluacion')::boolean,false),updated_at=now() where id=p_examen_id returning id into v_id;
  if v_id is null then raise exception 'No se encontró el examen que deseas editar.'; end if;
  delete from public.examen_preguntas where examen_id=v_id; delete from public.examen_destinatarios where examen_id=v_id;
 end if;
 for v_q in select value from jsonb_array_elements(p_preguntas) loop
  v_n:=v_n+1;
  if coalesce(v_q->>'tipo','') not in ('opcion_multiple','abierta','sopa_letras','crucigrama','relacionar') then raise exception 'Tipo de pregunta no válido.'; end if;
  if coalesce(trim(v_q->>'enunciado'),'')='' then raise exception 'Todas las preguntas necesitan un enunciado.'; end if;
  if coalesce((v_q->>'puntos')::numeric,1)<=0 then raise exception 'Los puntos de cada pregunta deben ser mayores que cero.'; end if;
  insert into public.examen_preguntas(examen_id,orden,tipo,enunciado,opciones,respuesta_correcta_idx,respuestas_aceptadas,puntos,config_jsonb)
  values(v_id,v_n-1,v_q->>'tipo',trim(v_q->>'enunciado'),v_q->'opciones',nullif(v_q->>'respuesta_correcta_idx','')::integer,v_q->'respuestas_aceptadas',coalesce((v_q->>'puntos')::numeric,1),coalesce(v_q->'config_jsonb','{}'::jsonb));
 end loop;
 if coalesce((p_examen->>'es_reevaluacion')::boolean,false) then insert into public.examen_destinatarios(examen_id,user_id) select v_id,u from (select distinct unnest(p_destinatarios) as u) x where u is not null; end if;
 return v_id;
end; $function$
;

revoke all on function public.iniciar_examen(uuid) from public, anon, authenticated;

grant execute on function public.iniciar_examen(uuid) to authenticated;

revoke all on function public.calificar_examen(uuid,jsonb) from public, anon, authenticated;

grant execute on function public.calificar_examen(uuid,jsonb) to authenticated;

revoke all on function public.guardar_examen_modular(uuid,jsonb,jsonb,uuid[]) from public, anon, authenticated;

grant execute on function public.guardar_examen_modular(uuid,jsonb,jsonb,uuid[]) to authenticated;