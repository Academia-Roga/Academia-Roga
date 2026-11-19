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