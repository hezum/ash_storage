defmodule AshStorage.MultitenancyTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations

  defmodule TenantDomain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.MultitenancyTest.TenantBlob
      resource AshStorage.MultitenancyTest.TenantAttachment
      resource AshStorage.MultitenancyTest.TenantPost
    end
  end

  defmodule TenantBlob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.MultitenancyTest.TenantDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.BlobResource]

    ets do
      private? true
    end

    multitenancy do
      strategy :context
    end

    blob do
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule TenantAttachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.MultitenancyTest.TenantDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.AttachmentResource]

    ets do
      private? true
    end

    multitenancy do
      strategy :context
    end

    attachment do
      blob_resource(AshStorage.MultitenancyTest.TenantBlob)
      belongs_to_resource(:tenant_post, AshStorage.MultitenancyTest.TenantPost)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule TenantPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.MultitenancyTest.TenantDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    multitenancy do
      strategy :context
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.MultitenancyTest.TenantBlob)
      attachment_resource(AshStorage.MultitenancyTest.TenantAttachment)

      has_one_attached :cover_image do
        variant(:upcased, AshStorage.Test.UppercaseVariant)
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, allow_nil?: false
    end

    actions do
      defaults [:read, :destroy, create: [:title], update: [:title]]

      create :create_with_blob do
        accept [:title]
        argument :cover_image_blob_id, :uuid, allow_nil?: true

        change {AshStorage.Changes.AttachBlob,
                argument: :cover_image_blob_id, attachment: :cover_image}
      end
    end
  end

  setup do
    AshStorage.Service.Test.reset!()
    %{tenant1: Ash.UUID.generate(), tenant2: Ash.UUID.generate()}
  end

  describe "Operations.attach with tenant" do
    test "creates blob and attachment with tenant", %{tenant1: tenant1} do
      post =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "test"}, tenant: tenant1)
        |> Ash.create!()

      assert {:ok, %{blob: blob, attachment: attachment}} =
               Operations.attach(post, :cover_image, "hello world",
                 filename: "hello.txt",
                 tenant: tenant1
               )

      assert blob.filename == "hello.txt"
      assert attachment.blob_id == blob.id
    end

    test "isolates data between tenants", %{tenant1: tenant1, tenant2: tenant2} do
      post1 =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "post1"}, tenant: tenant1)
        |> Ash.create!()

      post2 =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "post2"}, tenant: tenant2)
        |> Ash.create!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post1, :cover_image, "tenant1 data",
          filename: "t1.txt",
          tenant: tenant1
        )

      {:ok, %{blob: blob2}} =
        Operations.attach(post2, :cover_image, "tenant2 data",
          filename: "t2.txt",
          tenant: tenant2
        )

      assert [att1] = TenantAttachment |> Ash.Query.set_tenant(tenant1) |> Ash.read!()
      assert att1.blob_id == blob1.id

      assert [att2] = TenantAttachment |> Ash.Query.set_tenant(tenant2) |> Ash.read!()
      assert att2.blob_id == blob2.id
    end
  end

  describe "Operations.prepare_direct_upload with tenant" do
    test "creates blob with tenant", %{tenant1: tenant1} do
      {:ok, result} =
        Operations.prepare_direct_upload(TenantPost, :cover_image,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 12_345,
          tenant: tenant1
        )

      assert result.blob.filename == "photo.jpg"
    end
  end

  describe "AttachBlob change with tenant" do
    test "attaches pre-uploaded blob on create", %{tenant1: tenant1} do
      blob =
        TenantBlob
        |> Ash.Changeset.for_create(
          :create,
          %{
            key: AshStorage.generate_key(),
            filename: "photo.jpg",
            content_type: "image/jpeg",
            byte_size: 100,
            service_name: AshStorage.Service.Test
          },
          tenant: tenant1
        )
        |> Ash.create!()

      AshStorage.Service.Test.upload(blob.key, "direct data", AshStorage.Service.Context.new([]))

      post =
        TenantPost
        |> Ash.Changeset.for_create(
          :create_with_blob,
          %{
            title: "direct upload",
            cover_image_blob_id: blob.id
          },
          tenant: tenant1
        )
        |> Ash.create!()

      post = Ash.load!(post, [cover_image: :blob], tenant: tenant1)
      assert post.cover_image.blob.id == blob.id
    end
  end

  describe "on-demand variant generation with tenant" do
    test "generates the variant blob in the tenant and serves its url", %{tenant1: tenant1} do
      post =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "variant"}, tenant: tenant1)
        |> Ash.create!()

      {:ok, _attached} =
        Operations.attach(post, :cover_image, "hello world",
          filename: "hello.txt",
          content_type: "text/plain",
          tenant: tenant1
        )

      # Loading the variant URL triggers on-demand generation, which creates a
      # variant blob via the tenant-scoped blob resource. Without threading the
      # tenant into VariantGenerator the create fails and the URL calc is nil.
      post = Ash.load!(post, [:cover_image_upcased_url], tenant: tenant1)
      assert is_binary(post.cover_image_upcased_url)

      post = Ash.load!(post, [cover_image: [blob: :variants]], tenant: tenant1)
      variant = Enum.find(post.cover_image.blob.variants, &(&1.variant_name == "upcased"))
      assert variant != nil
      assert variant.variant_of_blob_id == post.cover_image.blob.id
      assert {:ok, "HELLO WORLD"} = AshStorage.Service.Test.download(variant.key, [])
    end

    test "does not leak a variant across tenants", %{tenant1: tenant1, tenant2: tenant2} do
      post1 =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "t1"}, tenant: tenant1)
        |> Ash.create!()

      {:ok, _attached} =
        Operations.attach(post1, :cover_image, "tenant one",
          filename: "t1.txt",
          content_type: "text/plain",
          tenant: tenant1
        )

      post1 = Ash.load!(post1, [:cover_image_upcased_url], tenant: tenant1)
      assert is_binary(post1.cover_image_upcased_url)

      # A different tenant with no attachment sees no variant.
      post2 =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "t2"}, tenant: tenant2)
        |> Ash.create!()

      post2 = Ash.load!(post2, [:cover_image_upcased_url], tenant: tenant2)
      assert is_nil(post2.cover_image_upcased_url)
    end
  end

  describe "dependent purge with tenant" do
    test "destroying a tenant record purges its attachment, blob, and file",
         %{tenant1: tenant1} do
      post =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "purge"}, tenant: tenant1)
        |> Ash.create!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "image data",
          filename: "photo.jpg",
          tenant: tenant1
        )

      assert AshStorage.Service.Test.exists?(blob.key)

      # has_one_attached defaults to dependent: :purge. The destroy runs the
      # dependent-purge change, which destroys the attachment + blob and deletes
      # the file. Without threading the tenant into those nested destroys the
      # operation fails for :context resources.
      Ash.destroy!(post, tenant: tenant1)

      refute AshStorage.Service.Test.exists?(blob.key)
      assert [] = TenantAttachment |> Ash.Query.set_tenant(tenant1) |> Ash.read!()
    end
  end
end
