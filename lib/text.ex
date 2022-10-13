defmodule Bonfire.Common.Text do
  use Bonfire.Common.Utils
  # import Untangle

  # @add_to_end "..."
  @sentence_seperator " "

  @checkbox_regex_unchecked ~r/\s\[\s\]/
  @checkbox_regex_unchecked_line ~r/\s\[\s\]\s(.*)$/mu
  @checkbox_regex_checked ~r/\s\[[X,x]\]/
  @checkbox_regex_checked_line ~r/\s\[[X,x]\]\s(.*)$/mu
  @checkbox_regex_checkbox_line ~r/^(\s*)[-|<li>]\s\[([ |X|x])\]\s(.*)$/mu
  @checked_box " <input type=\'checkbox\' checked=\'checked\'>"
  @unchecked_box " <input type=\'checkbox\'>"

  def blank?(str_or_nil), do: "" == str_or_nil |> to_string() |> String.trim()

  # |> debug("contains_html?")
  def contains_html?(string), do: Regex.match?(~r/<\/?[a-z][\s\S]*>/i, string)

  def truncate(text, max_length \\ 250, add_to_end \\ nil)

  def truncate(text, max_length, add_to_end) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) < (max_length || 250) do
      text
    else
      if is_binary(add_to_end) do
        length_with_add_to_end = max_length - String.length(add_to_end)
        String.slice(text, 0, length_with_add_to_end) <> add_to_end
      else
        String.slice(text, 0, max_length)
      end
    end
  end

  def truncate(text, _, _), do: text

  def sentence_truncate(input, length \\ 250, add_to_end \\ "") do
    if(String.length(input) > length) do
      do_sentence_truncate(input, length) <> add_to_end
    else
      input
    end
  end

  defp do_sentence_truncate(input, length \\ 250) do
    length_minus_1 = length - 1

    case input do
      <<result::binary-size(length_minus_1), @sentence_seperator, _::binary>> ->
        # debug("the substring ends with seperator (eg. -)")
        # i. e. "abc-def-ghi", 8 or "abc-def-", 8 -> "abc-def"
        result

      <<result::binary-size(length), @sentence_seperator, _::binary>> ->
        #  debug("the next char after the substring is seperator")
        # i. e. "abc-def-ghi", 7 or "abc-def-", 7 -> "abc-def"
        result

      <<_::binary-size(length)>> ->
        # debug("it is the exact length string")
        # i. e. "abc-def", 7 -> "abc-def"
        input

      _ when length <= 1 ->
        # debug("return an empty string if we reached the beginning of the string")
        ""

      _ ->
        # debug("otherwise look into shorter substring")
        do_sentence_truncate(input, length_minus_1)
    end
  end

  def underscore_truncate(input, length \\ 250) do
    if(String.length(input) > length) do
      do_underscore_truncate(input, length)
    else
      input
    end
  end

  defp do_underscore_truncate(input, length \\ 250) do
    length_minus_1 = length - 1

    case input do
      <<result::binary-size(length_minus_1), "_", _::binary>> ->
        # debug("the substring ends with seperator (eg. -)")
        # i. e. "abc-def-ghi", 8 or "abc-def-", 8 -> "abc-def"
        result

      <<result::binary-size(length), "_", _::binary>> ->
        #  debug("the next char after the substring is seperator")
        # i. e. "abc-def-ghi", 7 or "abc-def-", 7 -> "abc-def"
        result

      <<_::binary-size(length)>> ->
        # debug("it is the exact length string")
        # i. e. "abc-def", 7 -> "abc-def"
        input

      _ when length <= 1 ->
        # debug("return an empty string if we reached the beginning of the string")
        ""

      _ ->
        # debug("otherwise look into shorter substring")
        do_underscore_truncate(input, length_minus_1)
    end
  end

  def maybe_markdown_to_html(nothing)
      when not is_binary(nothing) or nothing == "" do
    nil
  end

  # def maybe_markdown_to_html("<p>"<>content) do
  #   content
  #   |> String.trim_trailing("</p>")
  #   |> maybe_markdown_to_html() # workaround for weirdness with Earmark's parsing of markdown within html
  # end
  # def maybe_markdown_to_html("<"<>_ = content) do
  #   maybe_markdown_to_html(" "<>content) # workaround for weirdness with Earmark's parsing of html when it starts a line
  # end
  def maybe_markdown_to_html("<" <> _ = content) do
    warn("not processing markup in content that starts with an HTML tag")
    content
  end

  def maybe_markdown_to_html(content) do
    # debug(content, "input")
    if module_enabled?(Earmark) do
      content
      |> Earmark.as_html!(
        inner_html: true,
        escape: false,
        smartypants: false,
        registered_processors: [
          # {"a", &md_add_target/1},
          {"h1", &md_heading_anchors/1},
          {"h2", &md_heading_anchors/1},
          {"h3", &md_heading_anchors/1},
          {"h4", &md_heading_anchors/1},
          {"h5", &md_heading_anchors/1},
          {"h6", &md_heading_anchors/1}
        ]
      )
      |> markdown_checkboxes()
    else
      content
    end

    # |> debug("output")
  end

  # This will only be applied to nodes as it will become a TagSpecificProcessors
  defp md_add_target(node) do
    # debug(node)
    if Regex.match?(
         ~r{\.x\.com\z},
         Earmark.AstTools.find_att_in_node(node, "href", "")
       ),
       do: Earmark.AstTools.merge_atts_in_node(node, target: "_blank"),
       else: node
  end

  defp md_heading_anchors({tag, attrs, text, extra} = _node) do
    # node
    # |> debug()
    {tag,
     [
       {"id", slug(text)}
     ], text, extra}
  end

  defp slug(text) when is_list(text), do: Enum.join(text, "-") |> slug()

  defp slug(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
    |> URI.encode()
  end

  @doc """
  It is recommended to call this before storing any that data is coming in from the user or from a remote instance
  """
  def maybe_sane_html(content) do
    if module_enabled?(HtmlSanitizeEx) do
      HtmlSanitizeEx.markdown_html(content)
    else
      content
    end
  end

  def text_only({:safe, content}), do: text_only(content)

  def text_only(content) when is_binary(content) do
    if module_enabled?(HtmlSanitizeEx) do
      HtmlSanitizeEx.strip_tags(content)
    else
      content
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
    end
  end

  def text_only(_content), do: nil

  def maybe_normalize_html("<p>" <> content) do
    # workaround for weirdness with Earmark's parsing of markdown within html
    maybe_normalize_html(content)
  end

  def maybe_normalize_html(html_string) do
    if module_enabled?(Floki) do
      html_string
      |> Floki.parse()
      |> Floki.raw_html()
    else
      html_string
    end
    |> String.trim("<p><br/></p>")
    |> String.trim("<br/>")
    |> debug(html_string)
  end

  def maybe_emote(content) do
    if module_enabled?(Emote) do
      Emote.convert_text(content)
    else
      content
    end
  end

  # open outside links in a new tab
  def normalise_links(content)
      when is_binary(content) and byte_size(content) > 20 do
    local_instance = Bonfire.Common.URIs.base_url()

    content
    # handle AP actors
    |> Regex.replace(
      ~r/(href=\")#{local_instance}\/pub\/actors\/(.+\")/U,
      ...,
      "\\1/character/\\2 data-phx-link=\"redirect\" data-phx-link-state=\"push\""
    )
    # handle AP objects
    |> Regex.replace(
      ~r/(href=\")#{local_instance}\/pub\/objects\/(.+\")/U,
      ...,
      "\\1/discussion/\\2 data-phx-link=\"redirect\" data-phx-link-state=\"push\""
    )
    # handle internal links
    |> Regex.replace(
      ~r/(href=\")#{local_instance}(.+\")/U,
      ...,
      "\\1\\2 data-phx-link=\"redirect\" data-phx-link-state=\"push\""
    )
    # handle external links
    |> Regex.replace(~r/(href=\"http.+\")/U, ..., "\\1 target=\"_blank\"")
  end

  def normalise_links(content), do: content

  def markdown_checkboxes(text) do
    text
    |> replace_checked_boxes()
    |> replace_unchecked_boxes()
  end

  defp replace_checked_boxes(text) do
    if String.match?(text, @checkbox_regex_checked) do
      String.replace(text, @checkbox_regex_checked, @checked_box)
    else
      text
    end
  end

  defp replace_unchecked_boxes(text) do
    if String.match?(text, @checkbox_regex_unchecked) do
      String.replace(text, @checkbox_regex_unchecked, @unchecked_box)
    else
      text
    end
  end

  def list_checked_boxes(text) do
    regex_list(@checkbox_regex_checked_line, text)
  end

  def list_unchecked_boxes(text) do
    regex_list(@checkbox_regex_unchecked_line, text)
  end

  def list_checkboxes(text) do
    regex_list(@checkbox_regex_checkbox_line, text)
  end

  def regex_list(regex, text) when is_binary(text) and text != "" do
    Regex.scan(regex, text)
  end

  def regex_list(text, regex), do: nil

  def upcase_first(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest

  def camelise(str) do
    words = ~w(#{str})

    Enum.into(words, [], fn word -> upcase_first(word) end)
    |> to_string()
  end

  def maybe_render_templated(templated_content, data)
      when is_binary(templated_content) and is_map(data) do
    if module_enabled?(Solid) and String.contains?(templated_content, "{{") do
      templated_content = templated_content |> String.replace("&quot;", "\"")

      with {:ok, template} <- Solid.parse(templated_content),
           {:ok, rendered} <- Solid.render(template, data) do
        rendered
        |> to_string()
      else
        {:error, error} ->
          error(error, templated_content)
          templated_content
      end
    else
      debug("Solid not used in block or not enabled - skipping parse/render template")
      templated_content
    end
  end

  def maybe_render_templated(content, data) do
    if Keyword.keyword?(data) do
      maybe_render_templated(content, Map.new(data))
    else
      warn("No pattern match on args, so can't parse/render template")
      content
    end
  end

  @doc """
  Uses the `Verbs` library to convert an English conjugated verb back to inifinitive form.
  Currently only supports irregular verbs.
  """
  def verb_infinitive(verb_conjugated) do
    with [{infinitive, _}] <-
           Enum.filter(Irregulars.verb_forms(), fn {infinitive, conjugations} ->
             verb_conjugated in conjugations
           end) do
      infinitive
    else
      _ ->
        nil
    end
  end
end
