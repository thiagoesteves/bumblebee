defmodule Bumblebee.Layers do
  @moduledoc false

  import Nx.Defn

  @unsupported_activations [:gelu_new, :quick_gelu]

  @pi :math.pi()

  @doc """
  Adds an activation layer.

  Handles all activations built into Axon, as well as several custom
  activations.

  ## Options

    * `:name` - layer name

  """
  def activation(%Axon{} = input, activation, opts \\ []) do
    opts = Keyword.validate!(opts, [:name])
    name = opts[:name]

    if activation in @unsupported_activations do
      Axon.activation(input, &apply(__MODULE__, activation, [&1, &2]), name: name)
    else
      Axon.activation(input, activation, name: name)
    end
  end

  @doc """
  Implements the GeLU new activation from huggingface/transformers.
  """
  defn gelu_new(input, _opts \\ []) do
    0.5 * input *
      (1.0 + Nx.tanh(Nx.sqrt(2.0 / @pi) * (input + 0.044715 * Nx.pow(input, 3.0))))
  end

  @doc """
  Implements the GeLU quick activation from huggingface/transformers.
  """
  defn quick_gelu(input, _opts \\ []) do
    input * Nx.sigmoid(1.702 * input)
  end

  @doc """
  Expands an attention mask of shape `{batch_size, sequence_length}` to
  a full mask.
  """
  def expand_attention_mask(attention_mask) do
    Axon.nx(attention_mask, fn attention_mask ->
      attention_mask
      |> Nx.new_axis(-2)
      |> Nx.new_axis(-2)
    end)
  end

  @doc """
  Converts attention mask to bias.
  """
  def attention_bias(attention_mask) do
    attention_mask
    |> Axon.optional()
    |> Axon.nx(fn
      %Axon.None{} ->
        Nx.tensor(0)

      attention_mask ->
        Nx.select(Nx.greater(attention_mask, 0), 0, -1.0e10)
    end)
  end

  @doc """
  Computes relative attention bias.
  """
  def relative_attention_bias(query, key, attention_cache, offset, opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :name,
        bidirectional: true,
        num_heads: 8,
        num_buckets: 32,
        max_distance: 128
      ])

    name = opts[:name]

    relative_position_buckets =
      Axon.layer(
        &compute_relative_position_buckets/4,
        [query, key, Axon.optional(attention_cache)],
        bidirectional: opts[:bidirectional],
        num_buckets: opts[:num_buckets],
        max_distance: opts[:max_distance]
      )

    bias =
      relative_position_buckets
      |> Axon.embedding(opts[:num_buckets], opts[:num_heads], name: name)
      |> Axon.transpose([2, 0, 1])
      |> Axon.nx(&Nx.new_axis(&1, 0))

    Axon.layer(
      fn bias, query, offset, _opts ->
        case offset do
          %Axon.None{} ->
            bias

          offset ->
            mask_shift = Nx.as_type(offset, {:s, 64})
            query_length = Nx.axis_size(query, 1)
            Nx.slice_along_axis(bias, mask_shift, query_length, axis: 2)
        end
      end,
      [bias, query, Axon.optional(offset)]
    )
  end

  defnp compute_relative_position_buckets(query, key, attention_cache, opts \\ []) do
    opts = keyword!(opts, mode: :train, bidirectional: true, num_buckets: 32, max_distance: 128)

    {key_length, query_length} = key_query_lengths(query, key, attention_cache)

    context_position = Nx.iota({query_length, 1})
    memory_position = Nx.iota({1, key_length})
    relative_position = memory_position - context_position

    {num_buckets, relative_buckets, relative_position} =
      bidirectional_buckets(relative_position, opts[:num_buckets], opts[:bidirectional])

    max_exact = Nx.quotient(num_buckets, 2)
    is_small = Nx.less(relative_position, max_exact)

    relative_position_if_large =
      max_exact +
        Nx.log(relative_position / max_exact) / Nx.log(opts[:max_distance] / max_exact) *
          (num_buckets - max_exact)

    relative_position_if_large =
      Nx.min(
        relative_position_if_large,
        Nx.broadcast(num_buckets - 1, Nx.shape(relative_position_if_large))
      )
      |> Nx.as_type(:s64)

    relative_buckets + Nx.select(is_small, relative_position, relative_position_if_large)
  end

  deftransformp key_query_lengths(query, key, attention_cache) do
    case attention_cache do
      %Axon.None{} ->
        {Nx.axis_size(key, 1), Nx.axis_size(query, 1)}

      attention_cache ->
        key_length = Nx.axis_size(attention_cache.key, 1)
        {key_length, key_length}
    end
  end

  deftransformp bidirectional_buckets(relative_position, num_buckets, bidirectional) do
    relative_buckets = 0

    if bidirectional do
      num_buckets = div(num_buckets, 2)

      relative_buckets =
        Nx.add(relative_buckets, Nx.multiply(Nx.greater(relative_position, 0), num_buckets))

      relative_position = Nx.abs(relative_position)
      {num_buckets, relative_buckets, relative_position}
    else
      relative_position =
        relative_position
        |> Nx.min(Nx.broadcast(0, Nx.shape(relative_position)))
        |> Nx.negate()

      {num_buckets, relative_buckets, relative_position}
    end
  end

  @doc """
  Computes attention weights.

  ## Options

    * `:scale_query?` - whether to scale the query. Defaults to `true`

  """
  def attention_weights(query, key, bias, opts \\ []) do
    Axon.layer(&attention_weights_impl/4, [query, key, bias], opts)
  end

  defnp attention_weights_impl(query, key, bias, opts \\ []) do
    opts = keyword!(opts, mode: :train, scale_query?: true)

    key = Nx.transpose(key, axes: [0, 2, 1, 3])
    query = Nx.transpose(query, axes: [0, 2, 1, 3])

    query =
      if opts[:scale_query?] do
        depth = Nx.axis_size(query, -1)
        query / Nx.sqrt(depth)
      else
        query
      end

    weights = Nx.dot(query, [3], [0, 1], key, [3], [0, 1])
    weights = weights + bias
    Axon.Activations.softmax(weights, axis: -1)
  end

  @doc """
  Computes attention outputs.
  """
  def attention_output(attention_weights, value) do
    Axon.layer(&attention_output_impl/3, [attention_weights, value])
  end

  defnp attention_output_impl(attention_weights, value, _opts \\ []) do
    value = Nx.transpose(value, axes: [0, 2, 1, 3])
    out = Nx.dot(attention_weights, [3], [0, 1], value, [2], [0, 1])
    Nx.transpose(out, axes: [0, 2, 1, 3])
  end

  @doc """
  Applies head mask to the given attention weights.

  This layer expects computed attention weights and an optional mask.
  If the mask is not specified, it will skip masking altogether.
  """
  def apply_attention_head_mask(attention_weights, head_mask) do
    if_present head_mask do
      Axon.layer(
        fn attention_weights, head_mask, _ ->
          head_mask = Nx.reshape(head_mask, {1, :auto, 1, 1})
          Nx.multiply(attention_weights, head_mask)
        end,
        [attention_weights, head_mask]
      )
    else
      attention_weights
    end
  end

  @doc """
  Adds a dense layer to the network.

  The kernel parameter is transposed with respect to `Axon.dense/3`.

  ## Options

    * `:name` - layer name

    * `:kernel_initializer` - initializer for `kernel` weights.
      Defaults to `:glorot_uniform`

  """
  def dense_transposed(%Axon{} = x, units, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, kernel_initializer: :glorot_uniform])

    kernel_shape = fn input_shape ->
      kernel_shape = Axon.Shape.dense_kernel(input_shape, units)

      # We expect a transposed kernel
      kernel_shape
      |> Tuple.to_list()
      |> Enum.reverse()
      |> List.to_tuple()
    end

    kernel = Axon.param("kernel", kernel_shape, initializer: opts[:kernel_initializer])

    op = fn x, kernel, _opts ->
      Nx.dot(x, [-1], kernel, [1])
    end

    Axon.layer(op, [x, kernel], name: opts[:name], op_name: :dense_transposed)
  end

  @doc """
  Adds a 1-dimensional convolution layer to the network.

  ## Options

    * `:name` - layer name.

    * `:kernel_initializer` - initializer for `kernel` weights.
      Defaults to `:glorot_uniform`.

    * `:bias_initializer` - initializer for `bias` weights. Defaults
      to `:zeros`

    * `:use_bias` - whether the layer should add bias to the output.
      Defaults to `true`

  """
  def conv1d(%Axon{} = x, units, opts) do
    opts =
      Keyword.validate!(opts, [
        :name,
        kernel_initializer: :glorot_uniform,
        bias_initializer: :zeros,
        use_bias: true
      ])

    kernel_shape = fn input_shape ->
      {elem(input_shape, tuple_size(input_shape) - 1), units}
    end

    bias_shape = fn _ -> {units} end

    kernel = Axon.param("kernel", kernel_shape, initializer: opts[:kernel_initializer])

    {inputs, op} =
      if opts[:use_bias] do
        bias = Axon.param("bias", bias_shape, initializer: opts[:bias_initializer])
        {[x, kernel, bias], &conv1d_impl/4}
      else
        {[x, kernel], &conv1d_impl(&1, &2, 0, &3)}
      end

    Axon.layer(op, inputs, name: opts[:name], op_name: :conv1d)
  end

  defnp conv1d_impl(input, kernel, bias, _opts \\ []) do
    input
    |> Nx.dot([Nx.rank(input) - 1], [], kernel, [0], [])
    |> Nx.add(bias)
  end

  @doc """
  Adds a scaling layer to the network.

  The scaling layer scales inputs by a learned scale parameter.

  ## Options

    * `:name` - layer name

    * `:scale_initializer` - initializer for the scale parameter

    * `:channel_index` - index of the axis to scale. Defaults to the
      last axis

  """
  def scale(%Axon{} = x, opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :name,
        scale_initializer: Axon.Initializers.full(1.0e-6),
        channel_index: -1
      ])

    name = opts[:name]
    scale_initializer = opts[:scale_initializer]
    channel_index = opts[:channel_index]

    scale_shape = fn input_shape ->
      rank = tuple_size(input_shape)
      channel_index = rem(rank + channel_index, rank)
      out_channels = elem(input_shape, channel_index)
      {out_channels}
    end

    scale_param = Axon.param("scale", scale_shape, initializer: scale_initializer)

    Axon.layer(
      fn input, scale, _opts ->
        channel_index = Nx.axis_index(input, channel_index)
        shape = Tuple.duplicate(1, Nx.rank(input)) |> put_elem(channel_index, :auto)
        scale = Nx.reshape(scale, shape)
        Nx.multiply(input, scale)
      end,
      [x, scale_param],
      name: name,
      op_name: :scale
    )
  end

  @doc """
  Adds a drop-path layer to the network for stochastic depth.

  ## Options

    * `:name` - layer name

    * `:rate` - drop path rate

  ## References

    * [Deep Networks with Stochastic Depth](https://arxiv.org/pdf/1603.09382.pdf)

  """
  def drop_path(%Axon{} = input, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, :seed, rate: 0.0])
    seed = Keyword.get_lazy(opts, :seed, fn -> :erlang.system_time() end)

    key_state =
      Axon.param("key", fn _ -> {2} end,
        type: {:u, 32},
        initializer: fn _, _ -> Nx.Random.key(seed) end
      )

    if opts[:rate] > 0.0 do
      Axon.layer(&drop_path_impl/3, [input, key_state],
        name: opts[:name],
        op_name: :drop_path,
        rate: opts[:rate]
      )
    else
      input
    end
  end

  deftransformp drop_path_impl(x, prng_key, opts \\ []) do
    opts = Keyword.validate!(opts, rate: 0.0, mode: :train)
    rate = opts[:rate]

    case opts[:mode] do
      :train ->
        keep_prob = 1 - rate
        shape = Tuple.duplicate(1, Nx.rank(x)) |> put_elem(0, Nx.axis_size(x, 0))

        {rand, next_key} = Nx.Random.uniform(prng_key, shape: shape)

        bernoulli_noise =
          keep_prob
          |> Nx.add(rand)
          |> Nx.floor()

        out =
          x
          |> Nx.divide(keep_prob)
          |> Nx.multiply(bernoulli_noise)

        %Axon.StatefulOutput{output: out, state: %{"key" => next_key}}

      _mode ->
        x
    end
  end

  @doc """
  Takes the first element along the given axis.

  This is a common operation in many architectures. It reduces
  dimensionality by dropping the given axis.

  ## Options

    * `:name` - layer name

    * `:axis` - axis to slice token from

    * `:index` - index to slice head. Defaults to 0

  """
  def take_token(%Axon{} = input, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, :axis, index: 0])

    Axon.nx(
      input,
      fn x ->
        x
        |> Nx.slice_along_axis(opts[:index], 1, axis: opts[:axis])
        |> Nx.squeeze(axes: [opts[:axis]])
      end,
      name: opts[:name]
    )
  end

  @doc """
  Implements position masking for embedded patches of visual inputs.

  This layer expects computed patch embeddings and an optional mask.
  If the mask is not specified, it will skip masking altogether.

  ## Options

    * `:name` - layer name

  """
  def apply_vision_patch_mask(%Axon{} = embeddings, patch_mask, opts \\ []) do
    opts = Keyword.validate!(opts, [:name])
    name = opts[:name]

    mask_token_shape = fn embeddings_shape, _ ->
      hidden_size = elem(embeddings_shape, 2)
      {1, 1, hidden_size}
    end

    mask_token = Axon.param("mask_token", mask_token_shape, initializer: :zeros)

    if_present patch_mask do
      Axon.layer(
        fn embeddings, patch_mask, mask_tokens, _opts ->
          hidden_size = Nx.axis_size(embeddings, 2)
          batch_size = Nx.axis_size(embeddings, 0)
          sequence_length = Nx.axis_size(embeddings, 1)
          mask_tokens = Nx.broadcast(mask_tokens, {batch_size, sequence_length, hidden_size})

          mask =
            patch_mask
            |> Nx.new_axis(-1)
            |> Nx.broadcast({batch_size, sequence_length, hidden_size})

          Nx.select(mask, mask_tokens, embeddings)
        end,
        [embeddings, patch_mask, mask_token],
        name: name,
        op_name: :apply_patch_mask
      )
    else
      embeddings
    end
  end

  @doc """
  Splits the hidden dimension into the given number of attention heads.

  In other words, the input with shape `{batch_size, sequence_length, hidden_size}`
  is reshaped to `{batch_size, sequence_length, num_heads, *}`.
  """
  def split_heads(states, num_heads) do
    Axon.nx(states, fn states ->
      batch_size = Nx.axis_size(states, 0)
      sequence_length = Nx.axis_size(states, 1)
      new_shape = {batch_size, sequence_length, num_heads, :auto}
      Nx.reshape(states, new_shape)
    end)
  end

  @doc """
  Splits the input node with shape `{bach_size, sequence_length, 2}` into
  two nodes with shape `{batch_size, sequence_length}`.
  """
  def split_pair(%Axon{} = x) do
    left = Axon.nx(x, & &1[[0..-1//1, 0..-1//1, 0]])
    right = Axon.nx(x, & &1[[0..-1//1, 0..-1//1, 1]])
    {left, right}
  end

  @doc """
  Adds a layer to the network which flattens the leading axes of the
  input.
  """
  def flatten_leading(%Axon{} = x) do
    Axon.nx(x, fn x ->
      shape =
        x
        |> Nx.shape()
        |> Tuple.delete_at(0)
        |> put_elem(0, :auto)

      Nx.reshape(x, shape)
    end)
  end

  @doc """
  Adds a layer to the network which flattens the trailing axes of the
  input.
  """
  def flatten_trailing(%Axon{} = x) do
    Axon.nx(x, fn x ->
      shape = Nx.shape(x)
      rank = tuple_size(shape)

      shape =
        shape
        |> Tuple.delete_at(rank - 1)
        |> put_elem(rank - 2, :auto)

      Nx.reshape(x, shape)
    end)
  end

  @doc """
  Adds a pixel rearrangement layer to the network.

  Rearranges elements in a tensor of shape `{*, H, W, C × r^2}` to a
  tensor of shape `{*, H × r, W × r, C}`, where r is an upscale factor.

  This is useful for implementing efficient sub-pixel convolution
  with a stride of `1 / r`.

  ## Options

    * `:name` - layer name

  """
  def pixel_shuffle(input, upscale_factor, opts \\ []) do
    opts = Keyword.validate!(opts, [:name])

    Axon.layer(&pixel_shuffle_impl/2, [input],
      name: opts[:name],
      op_name: :pixel_shuffle,
      upscale_factor: upscale_factor
    )
  end

  deftransformp pixel_shuffle_impl(input, opts \\ []) do
    opts = Keyword.validate!(opts, [:upscale_factor, mode: :inference])
    upscale_factor = opts[:upscale_factor]

    {batch, [height, width, channels]} =
      input
      |> Nx.shape()
      |> Tuple.to_list()
      |> Enum.split(-3)

    out_height = height * upscale_factor
    out_width = width * upscale_factor
    out_channels = div(channels, upscale_factor * upscale_factor)

    x =
      Nx.reshape(
        input,
        List.to_tuple(batch ++ [height, width, out_channels, upscale_factor, upscale_factor])
      )

    {batch_axes, [height_axis, width_axis, out_channels_axis, upscale_axis1, upscale_axis2]} =
      x
      |> Nx.axes()
      |> Enum.split(-5)

    x
    |> Nx.transpose(
      axes:
        batch_axes ++ [height_axis, upscale_axis1, width_axis, upscale_axis2, out_channels_axis]
    )
    |> Nx.reshape(List.to_tuple(batch ++ [out_height, out_width, out_channels]))
  end

  @doc """
  Adds a layer that that computes cosine similarity between the inputs.
  """
  def cosine_similarity(x, y) do
    Axon.layer(&cosine_similarity_impl/3, [x, y], op_names: :cosine_similarity)
  end

  defnp cosine_similarity_impl(x, y, _opts \\ []) do
    Bumblebee.Utils.Nx.cosine_similarity(x, y)
  end

  @doc """
  Unwraps a tuple result from `Axon` node into separate nodes.
  """
  def unwrap_tuple(%Axon{} = input, size) do
    for i <- 0..(size - 1) do
      Axon.nx(input, &elem(&1, i))
    end
    |> List.to_tuple()
  end

  @doc """
  Adds a default layer to handle optional nodes.

  This layer evaluates to the result of `x` if present, otherwise
  falls back to the result of the default node.

  ## Examples

      input_ids = Axon.input("input_ids")
      attention_mask = Axon.input("attention_mask", optional: true)

      attention_mask =
        Bumblebee.Layers.default attention_mask do
          Axon.nx(input_ids, &Nx.broadcast(1, &1))
        end

  """
  def default(%Axon{} = x, do: default) do
    Axon.layer(
      fn x, default, _ ->
        case x do
          %Axon.None{} -> default
          _ -> x
        end
      end,
      [Axon.optional(x), Axon.optional(default)],
      op_name: :default
    )
  end

  @doc """
  Adds a conditional layer.

  This layer evaluates to either branch, depending on whether the
  optional `condition` value is present or missing.

  The branches can be either `Axon` nodes or `Nx.Container`s with
  `Axon` nodes and the same structure. If containers are given, this
  function also returns a matching container.

  ## Examples

      {hidden_state, cross_attention} =
        Bumblebee.Layers.if_present encoder_hidden_state do
          ...
          {hidden_state, cross_attention}
        else
          {hidden_state, Bumblebee.Layers.none()}
        end

  """
  def if_present(%Axon{} = condition, blocks) do
    on_true = Keyword.fetch!(blocks, :do)
    on_false = blocks[:else]

    case {on_true, on_false} do
      {%Axon{}, %Axon{}} ->
        if_present_layer(condition, on_true, on_false)

      {%Axon{}, nil} ->
        if_present_layer(condition, on_true, none())

      _ ->
        on_false = on_false || Bumblebee.Utils.Axon.container_map(on_true, fn _ -> none() end)

        Bumblebee.Utils.Axon.container_zip_with(on_true, on_false, fn left, right ->
          if_present_layer(condition, left, right)
        end)
    end
  end

  defp if_present_layer(condition, on_true, on_false) do
    Axon.layer(
      fn condition, on_true, on_false, _ ->
        case condition do
          %Axon.None{} -> on_false
          _ -> on_true
        end
      end,
      [Axon.optional(condition), Axon.optional(on_true), Axon.optional(on_false)],
      op_name: :if_present
    )
  end

  @doc """
  Returns an Axon layer that resolves to `%Axon.None{}`.
  """
  def none() do
    Axon.layer(fn _opts -> %Axon.None{} end, [], op_name: :none)
  end

  @doc """
  Returns a container layer if `condition` is truthy, otherwise returns
  a none layer.
  """
  def maybe_container(container, condition) do
    if condition do
      Axon.container(container)
    else
      none()
    end
  end

  @doc """
  Performs `Tuple.append/1` on node results.
  """
  def append(%Axon{} = tuple, %Axon{} = x) do
    Axon.layer(fn tuple, x, _ -> Tuple.append(tuple, x) end, [tuple, x], op_name: :append)
  end

  @doc """
  Builds an `Axon` container with the given outputs.

  All values are wrapped with `Axon.optional/2`, so if any of them is
  missing, it gets returned as `%Axon.None{}`.
  """
  @spec output(map()) :: Axon.t()
  def output(outputs) do
    outputs
    |> Map.new(fn
      {key, %Axon{} = val} -> {key, Axon.optional(val)}
      {key, val} -> {key, val}
    end)
    |> Axon.container()
  end

  @doc """
  Computes a 1-full mask matching the first two dimensions of `input`
  (batch size and sequence length).
  """
  def default_attention_mask(%Axon{} = input) do
    Axon.nx(input, fn input ->
      batch_size = Nx.axis_size(input, 0)
      sequence_length = Nx.axis_size(input, 1)
      Nx.broadcast(1, {batch_size, sequence_length})
    end)
  end

  @doc """
  Computes increasing position ids matching the first two dimensions
  of `input` (batch size and sequence length).

  ## Options

    * `:offset` - the index of the first position. Defaults to `0`

  """
  def default_position_ids(%Axon{} = input, opts \\ []) do
    opts = Keyword.validate!(opts, offset: 0)
    offset = opts[:offset]

    Axon.nx(input, fn input ->
      batch_size = Nx.axis_size(input, 0)
      sequence_length = Nx.axis_size(input, 1)
      Nx.iota({batch_size, sequence_length}, axis: -1) |> Nx.add(offset)
    end)
  end

  @doc """
  Computes 0-full mask matching the first two dimensions of `input`
  (batch size and sequence length).
  """
  def default_token_type_ids(%Axon{} = input) do
    Axon.nx(input, fn input ->
      batch_size = Nx.axis_size(input, 0)
      sequence_length = Nx.axis_size(input, 1)
      Nx.broadcast(0, {batch_size, sequence_length})
    end)
  end

  @doc """
  Computes 0-full bounding box for document-understanding models.
  """
  def default_bounding_box(%Axon{} = input) do
    Axon.nx(input, fn input ->
      batch_size = Nx.axis_size(input, 0)
      sequence_length = Nx.axis_size(input, 1)
      Nx.broadcast(0, {batch_size, sequence_length, 4})
    end)
  end

  @doc """
  Shifts the given input ids by removing the last token and prepending
  the given start token.

  Some models use this technique to generate default decoder input ids.
  """
  def shift_tokens_right(%Axon{} = input_ids, decoder_start_token_id) do
    Axon.nx(input_ids, fn input_ids ->
      batch_size = Nx.axis_size(input_ids, 0)
      sequence_length = Nx.axis_size(input_ids, 1)
      start_ids = Nx.broadcast(decoder_start_token_id, {batch_size, 1})

      if sequence_length == 1 do
        start_ids
      else
        Nx.concatenate([start_ids, input_ids[[0..-1//1, 0..-2//1]]], axis: 1)
      end
    end)
  end

  @doc """
  Returns a node with parameterized embeddings.

  ## Options

    * `:name` - layer name

    * `:initializer` - initializer for the embeddings. Defaults to
      `:zeros`

  """
  def learned_embeddings(num_embeddings, embedding_size, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, initializer: :zeros])

    name = opts[:name]

    embeddings =
      Axon.param("embeddings", fn -> {num_embeddings, embedding_size} end,
        initializer: opts[:initializer]
      )

    Axon.layer(
      fn embeddings, _opts -> Nx.new_axis(embeddings, 0) end,
      [embeddings],
      name: name,
      op_name: :learned_embeddings
    )
  end

  @doc """
  Prepends a single parameterized embedding to the given embeddings.

  This is usually useful when adding embeddings for special tokens,
  such as CLS, in transformer models where the input is different
  than text, hence the token is not a part of the input.
  """
  def prepend_embedding(embeddings, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, initializer: :zeros])

    name = opts[:name]

    embedding =
      Axon.param("embedding", fn embeddings -> {elem(embeddings, 2)} end,
        initializer: opts[:initializer]
      )

    Axon.layer(
      fn embeddings, embedding, _opts ->
        batch_size = Nx.axis_size(embeddings, 0)
        embedding_size = Nx.axis_size(embeddings, -1)

        embedding =
          embedding
          |> Nx.reshape({1, 1, embedding_size})
          |> Nx.broadcast({batch_size, 1, embedding_size})

        Nx.concatenate([embedding, embeddings], axis: 1)
      end,
      [embeddings, embedding],
      name: name,
      op_name: :prepend_embedding
    )
  end

  @doc """
  Adds an RMS Normalization layer to the network.
  """
  # TODO: Add to Axon
  def rms_norm(input, opts \\ []) do
    opts =
      Keyword.validate!(opts, [:name, channel_index: -1, epsilon: 1.0e-6, initializer: :ones])

    weight =
      Axon.param("weight", &Axon.Shape.norm_param(&1, opts[:channel_index]),
        initializer: opts[:initializer]
      )

    Axon.layer(&rms_norm_impl/3, [input, weight], name: opts[:name], epsilon: opts[:epsilon])
  end

  defnp rms_norm_impl(input, weight, opts \\ []) do
    opts = keyword!(opts, epsilon: 1.0e-6, channel_index: -1, mode: :train)

    variance =
      input
      |> Nx.pow(2)
      |> Nx.mean(axes: [opts[:channel_index]], keep_axes: true)

    x =
      input
      |> Nx.multiply(Nx.rsqrt(variance + opts[:epsilon]))

    x * weight
  end
end
