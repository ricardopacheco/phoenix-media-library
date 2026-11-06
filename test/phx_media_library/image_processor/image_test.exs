defmodule PhxMediaLibrary.ImageProcessor.ImageTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Conversion
  alias PhxMediaLibrary.ImageProcessor.Image, as: Processor

  setup do
    {:ok, image} = Image.new(400, 200, color: :red)
    {:ok, image: image}
  end

  defp size(image), do: {Image.width(image), Image.height(image)}

  describe "apply_conversion/2 resizing" do
    test "a width-only conversion scales to that width, keeping the aspect ratio", %{
      image: image
    } do
      assert {:ok, out} = Processor.apply_conversion(image, Conversion.new(:preview, width: 100))
      assert size(out) == {100, 50}
    end

    test "a height-only conversion scales to that height, keeping the aspect ratio", %{
      image: image
    } do
      assert {:ok, out} = Processor.apply_conversion(image, Conversion.new(:tall, height: 50))
      assert size(out) == {100, 50}
    end

    test "width and height with fit: :cover fill the box", %{image: image} do
      conversion = Conversion.new(:thumb, width: 50, height: 50, fit: :cover)
      assert {:ok, out} = Processor.apply_conversion(image, conversion)
      assert size(out) == {50, 50}
    end

    test "no dimensions leaves the image as is", %{image: image} do
      assert {:ok, out} = Processor.apply_conversion(image, Conversion.new(:same, quality: 80))
      assert size(out) == {400, 200}
    end
  end
end
