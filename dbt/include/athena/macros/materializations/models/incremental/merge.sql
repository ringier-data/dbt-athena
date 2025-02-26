{% macro get_merge_update_columns(merge_update_columns, merge_exclude_columns, dest_columns) %}

  {%- if merge_update_columns and merge_exclude_columns -%}
    {{ exceptions.raise_compiler_error(
        'Model cannot specify merge_update_columns and merge_exclude_columns. Please update model to use only one config'
    )}}
  {%- elif merge_update_columns -%}
    {%- set update_columns = [] -%}
    {%- for column in dest_columns -%}
      {% if column.column | lower in merge_update_columns | map("lower") | list %}
        {%- do update_columns.append(column) -%}
      {% endif %}
    {%- endfor -%}
  {%- elif merge_exclude_columns -%}
    {%- set update_columns = [] -%}
    {%- for column in dest_columns -%}
      {% if column.column | lower not in merge_exclude_columns | map("lower") | list %}
        {%- do update_columns.append(column) -%}
      {% endif %}
    {%- endfor -%}
  {%- else -%}
    {%- set update_columns = dest_columns -%}
  {%- endif -%}

  {{ return(update_columns) }}

{% endmacro %}

{%- macro get_update_statement(col, rule, is_last) -%}
    {%- if rule == "coalesce" -%}
        {{ col.quoted }} = {{ 'coalesce(src.' + col.quoted + ', target.' + col.quoted + ')' }}
    {%- elif rule == "sum" -%}
      {%- if col.data_type.startswith("map") -%}
          {{ col.quoted }} = {{ 'map_zip_with(coalesce(src.' + col.quoted + ', map()), coalesce(target.' + col.quoted + ', map()), (k, v1, v2) -> coalesce(v1, 0) + coalesce(v2, 0))' }}
      {%- else -%}
        {{ col.quoted }} = {{ 'src.' + col.quoted + ' + target.' + col.quoted }}
      {%- endif -%}
    {%- elif rule == "append" -%}
        {{ col.quoted }} = {{ 'src.' + col.quoted + ' || target.' + col.quoted }}
    {%- elif rule == "append_distinct" -%}
        {{ col.quoted }} = {{ 'array_distinct(src.' + col.quoted + ' || target.' + col.quoted + ')' }}
    {%- elif rule == "replace" -%}
        {{ col.quoted }} = {{ 'src.' + col.quoted }}
    {%- else -%}
        {{ col.quoted }} = {{ rule | replace("_new_", 'src.' + col.quoted) | replace("_old_", 'target.' + col.quoted) }}
    {%- endif -%}
    {{ "," if not is_last }}
{%- endmacro -%}

{% macro iceberg_merge(on_schema_change, tmp_relation, target_relation, unique_key, existing_relation, delete_condition, statement_name="main") %}
    {%- set merge_update_columns = config.get('merge_update_columns') -%}
    {%- set merge_exclude_columns = config.get('merge_exclude_columns') -%}
    {%- set merge_update_columns_default_rule = config.get('merge_update_columns_default_rule', 'replace') -%}
    {%- set merge_update_columns_rules = config.get('merge_update_columns_rules') -%}

    {% set dest_columns = process_schema_changes(on_schema_change, tmp_relation, existing_relation) %}
    {% if not dest_columns %}
      {%- set dest_columns = adapter.get_columns_in_relation(target_relation) -%}
    {% endif %}
    {%- set dest_cols_csv = dest_columns | map(attribute='quoted') | join(', ') -%}
    {%- if unique_key is sequence and unique_key is not string -%}
      {%- set unique_key_cols = unique_key -%}
    {%- else -%}
      {%- set unique_key_cols = [unique_key] -%}
    {%- endif -%}
    {%- set src_columns_quoted = [] -%}
    {%- set dest_columns_wo_keys = [] -%}
    {%- for col in dest_columns -%}
      {%- do src_columns_quoted.append('src.' + col.quoted ) -%}
      {%- if col.name not in unique_key_cols -%}
        {%- do dest_columns_wo_keys.append(col) -%}
      {%- endif -%}
    {%- endfor -%}
    {%- set update_columns = get_merge_update_columns(merge_update_columns, merge_exclude_columns, dest_columns_wo_keys) -%}
    {%- set src_cols_csv = src_columns_quoted | join(', ') -%}
    merge into {{ target_relation }} as target using {{ tmp_relation }} as src
    on (
      {%- for key in unique_key_cols %}
        target.{{ key }} = src.{{ key }} {{ "and " if not loop.last }}
      {%- endfor %}
    )
    {% if delete_condition is not none -%}
    when matched and ({{ delete_condition }})
      then delete
    {%- endif %}
    when matched
      then update set
        {%- for col in update_columns %}
          {%- if merge_update_columns_rules and col.name in merge_update_columns_rules %}
            {{ get_update_statement(col, merge_update_columns_rules[col.name], loop.last) }}
          {%- else -%}
            {{ get_update_statement(col, merge_update_columns_default_rule, loop.last) }}
          {%- endif -%}
        {%- endfor %}
    when not matched
      then insert ({{ dest_cols_csv }})
       values ({{ src_cols_csv }});
{%- endmacro %}
