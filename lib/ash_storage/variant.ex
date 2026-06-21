defmodule AshStorage.Variant do
  @moduledoc """
  Behaviour for file variants that transform files into other files.

  Variants generate transformed versions of uploaded files — image thumbnails,
  PDF previews, video thumbnails, format conversions, etc.

  ## Implementing a Variant

      defmodule MyApp.Storage.Thumbnail do
        @behaviour AshStorage.Variant

        @impl true
        def accept?(content_type), do: String.starts_with?(content_type, "image/")

        @impl true
        def transform(source_path, dest_path, opts) do
          width = Keyword.get(opts, :width, 200)
          height = Keyword.get(opts, :height, 200)
          # Use an image library to resize
          Image.thumbnail!(source_path, "\#{width}x\#{height}", crop: :center)
          |> Image.write!(dest_path)
          {:ok, %{content_type: "image/webp"}}
        end
      end
  """

  @doc """
  Returns true if this variant can handle the given content type.
  """
  @callback accept?(content_type :: String.t()) :: boolean()

  @doc """
  Transform a file and return the result.

  Reads the file at `source_path` and applies the transformation. There are two
  ways to return the result:

  - Write the result to `dest_path` and return `{:ok, metadata}`, or
  - Return the encoded bytes directly as `{:ok, metadata, binary}` (no file I/O
    on `dest_path`). Prefer this when the transform already holds the output in
    memory — it avoids a temp-file round trip.

  `metadata` is a map that can include:

  - `:content_type` — the MIME type of the output file
  - `:filename` — override filename for the variant blob

  Any other keys are stored in the variant blob's metadata.
  """
  @callback transform(
              source_path :: String.t(),
              dest_path :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:ok, map(), binary()} | {:error, term()}
end
