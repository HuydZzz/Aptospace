module mint_nft::minting {
    use std::error;
    use std::signer;
    use std::string::{Self, String, utf8};
    use std::vector;

    use aptos_framework::account::{Self, SignerCapability, create_signer_with_capability};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::resource_account;
    use aptos_framework::timestamp;
    use aptos_token::token::{Self, TokenMutabilityConfig, create_token_mutability_config, create_collection, create_tokendata, TokenId};
    use mint_nft::big_vector::{Self, BigVector};
    use mint_nft::bucket_table::{Self, BucketTable};

    struct NFTMintConfig has key {
        admin: address,
        treasury: address,
        signer_cap: SignerCapability,
        token_minting_events: EventHandle<NFTMintMintingEvent>,
    }

    struct CollectionConfig has key {
        collection_name: String,
        collection_description: String,
        collection_maximum: u64,
        collection_uri: String,
        collection_mutate_config: vector<bool>,
        // this is base name, when minting, we will generate the actual token name as `token_name_base: sequence number`
        token_name_base: String,
        token_counter: u64,
        royalty_payee_address: address,
        token_description: String,
        token_maximum: u64,
        token_mutate_config: TokenMutabilityConfig,
        royalty_points_den: u64,
        royalty_points_num: u64,
        tokens: BigVector<TokenAsset>,
        // Here, we use a bucket table as a set to check duplicates.
        // The `key` is the uri of the token asset and values are all `true`.
        added_tokens: BucketTable<String, bool>,
        public_mint_limit_per_address: u64,
    }

    struct TokenAsset has drop, store {
        token_uri: String,
        property_keys: vector<String>,
        property_values: vector<vector<u8>>,
        property_types: vector<String>,
    }

    struct WhitelistMintConfig has key {
        whitelisted_address: BucketTable<address, u64>,
        whitelist_mint_price: u64,
        whitelist_minting_start_time: u64,
        whitelist_minting_end_time: u64,
    }

    struct PublicMintConfig has key {
        public_minting_addresses: BucketTable<address, u64>,
        public_mint_price: u64,
        public_minting_start_time: u64,
        public_minting_end_time: u64,
    }

    struct NFTMintMintingEvent has drop, store {
        token_receiver_address: address,
        token_id: TokenId,
    }

    const ENOT_AUTHORIZED: u64 = 1;
    const EINVALID_TIME: u64 = 2;
    const EACCOUNT_DOES_NOT_EXIST: u64 = 3;
    const EVECTOR_LENGTH_UNMATCHED: u64 = 4;
    const EEXCEEDS_COLLECTION_MAXIMUM: u64 = 5;
    const EINVALID_PRICE: u64 = 6;
    const EINVALID_UPDATE_AFTER_MINTING: u64 = 7;
    const EMINTING_IS_NOT_ENABLED: u64 = 8;
    const ENO_ENOUGH_TOKENS_LEFT: u64 = 9;
    const EACCOUNT_NOT_WHITELISTED: u64 = 10;
    const EINVALID_ROYALTY_NUMERATOR_DENOMINATOR: u64 = 11;
    const ECOLLECTION_ALREADY_CREATED: u64 = 12;
    const ECONFIG_NOT_INITIALIZED: u64 = 13;
    const EAMOUNT_EXCEEDS_MINTS_ALLOWED: u64 = 14;
    const EDUPLICATED_TOKENS: u64 = 15;
    const ECANNOT_REMOVE_EXISTING_WHITELIST_CONFIG: u64 = 16;

    fun init_module(resource_account: &signer) {
        let resource_signer_cap = resource_account::retrieve_resource_account_cap(resource_account, @source_addr);
        move_to(resource_account, NFTMintConfig {
            admin: @source_addr,
            treasury: @source_addr,
            signer_cap: resource_signer_cap,
            token_minting_events: account::new_event_handle<NFTMintMintingEvent>(resource_account),
        });
    }

    public entry fun set_admin(admin: &signer, new_admin_address: address) acquires NFTMintConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        assert!(signer::address_of(admin) == nft_mint_config.admin, error::permission_denied(ENOT_AUTHORIZED));
        nft_mint_config.admin = new_admin_address;
    }

    public entry fun set_treasury(admin: &signer, new_treasury_address: address) acquires NFTMintConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        assert!(signer::address_of(admin) == nft_mint_config.admin, error::permission_denied(ENOT_AUTHORIZED));
        nft_mint_config.treasury = new_treasury_address;
    }

    // the initial admin account will be the source account (which created the resource account);
    // the source account can update the NFTMintConfig struct
    public entry fun set_collection_config_and_create_collection(
        admin: &signer,
        collection_name: String,
        collection_description: String,
        collection_maximum: u64,
        collection_uri: String,
        collection_mutate_config: vector<bool>,
        token_name_base: String,
        royalty_payee_address: address,
        token_description: String,
        token_maximum: u64,
        token_mutate_config: vector<bool>,
        royalty_points_den: u64,
        royalty_points_num: u64,
        public_mint_limit_per_address: u64,
    ) acquires NFTMintConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        assert!(signer::address_of(admin) == nft_mint_config.admin, error::permission_denied(ENOT_AUTHORIZED));

        assert!(vector::length(&collection_mutate_config) == 3 && vector::length(&token_mutate_config) == 5, error::invalid_argument(EVECTOR_LENGTH_UNMATCHED));
        assert!(royalty_points_den > 0 && royalty_points_num < royalty_points_den, error::invalid_argument(EINVALID_ROYALTY_NUMERATOR_DENOMINATOR));
        assert!(!exists<CollectionConfig>(@mint_nft), error::permission_denied(ECOLLECTION_ALREADY_CREATED));

        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        let resource_account = create_signer_with_capability(&nft_mint_config.signer_cap);
        move_to(&resource_account, CollectionConfig {
            collection_name,
            collection_description,
            collection_maximum,
            collection_uri,
            collection_mutate_config,
            token_name_base,
            token_counter: 1,
            royalty_payee_address,
            token_description,
            token_maximum,
            token_mutate_config: create_token_mutability_config(&token_mutate_config),
            royalty_points_den,
            royalty_points_num,
            tokens: big_vector::new<TokenAsset>(128),
            added_tokens: bucket_table::new<String, bool>(128),
            // value 0 means that there's no limit
            public_mint_limit_per_address,
        });

        let resource_signer = create_signer_with_capability(&nft_mint_config.signer_cap);
        create_collection(&resource_signer, collection_name, collection_description, collection_uri, collection_maximum, collection_mutate_config);
    }

    public entry fun set_minting_time_and_price(
        admin: &signer,
        whitelist_minting_start_time: u64,
        whitelist_minting_end_time: u64,
        whitelist_mint_price: u64,
        public_minting_start_time: u64,
        public_minting_end_time: u64,
        public_mint_price: u64,
    ) acquires NFTMintConfig, WhitelistMintConfig, PublicMintConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        assert!(signer::address_of(admin) == nft_mint_config.admin, error::permission_denied(ENOT_AUTHORIZED));

        let now = timestamp::now_seconds();

        // whitelist_minting_start_time of value 0 indicates that the NFT project doesn't have a whitelist
        if (whitelist_minting_start_time > 0) {
            // assert that we are setting the whitelist time to sometime in the future
            assert!(whitelist_minting_start_time > now && whitelist_minting_start_time < whitelist_minting_end_time, error::invalid_argument(EINVALID_TIME));
            // assert that the public minting starts after the whitelist minting ends
            assert!(public_minting_start_time > whitelist_minting_end_time && public_minting_start_time < public_minting_end_time, error::invalid_argument(EINVALID_TIME));
            // assert that the public minting price is equal or more expensive than the whitelist minting price
            assert!(public_mint_price >= whitelist_mint_price, error::invalid_argument(EINVALID_PRICE));
        };

        if (exists<WhitelistMintConfig>(@mint_nft)) {
            assert!(whitelist_minting_start_time > 0, error::invalid_argument(ECANNOT_REMOVE_EXISTING_WHITELIST_CONFIG));
            let whitelist_mint_config = borrow_global_mut<WhitelistMintConfig>(@mint_nft);
            whitelist_mint_config.whitelist_minting_start_time = whitelist_minting_start_time;
            whitelist_mint_config.whitelist_minting_end_time = whitelist_minting_end_time;
            whitelist_mint_config.whitelist_mint_price = whitelist_mint_price;
        } else {
            if (whitelist_minting_start_time != 0) {
                let resource_account = create_signer_with_capability(&nft_mint_config.signer_cap);
                move_to(&resource_account, WhitelistMintConfig {
                    whitelisted_address: bucket_table::new<address, u64>(128),
                    whitelist_minting_start_time,
                    whitelist_minting_end_time,
                    whitelist_mint_price,
                });
            };
        };

        if (exists<PublicMintConfig>(@mint_nft)) {
            let public_mint_config = borrow_global_mut<PublicMintConfig>(@mint_nft);
            public_mint_config.public_minting_start_time = public_minting_start_time;
            public_mint_config.public_minting_end_time = public_minting_end_time;
            public_mint_config.public_mint_price = public_mint_price;
        } else {
            let resource_account = create_signer_with_capability(&nft_mint_config.signer_cap);
            move_to(&resource_account, PublicMintConfig {
                public_minting_addresses: bucket_table::new<address, u64>(8),
                public_minting_start_time,
                public_minting_end_time,
                public_mint_price,
            });
        };
    }

    public entry fun add_to_whitelist(
        admin: &signer,
        wl_addresses: vector<address>,
        mint_limit: u64
    ) acquires NFTMintConfig, WhitelistMintConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        assert!(signer::address_of(admin) == nft_mint_config.admin, error::permission_denied(ENOT_AUTHORIZED));
        assert!(exists<WhitelistMintConfig>(@mint_nft), error::permission_denied(ECONFIG_NOT_INITIALIZED));
        // cannot update whitelisted addresses if the whitelist minting period has already passed
        let whitelist_mint_config = borrow_global_mut<WhitelistMintConfig>(@mint_nft);
        assert!(whitelist_mint_config.whitelist_minting_end_time > timestamp::now_seconds(), error::permission_denied(EINVALID_UPDATE_AFTER_MINTING));

        let i = 0;
        while (i < vector::length(&wl_addresses)) {
            let addr = *vector::borrow(&wl_addresses, i);
            // assert that the specified address exists
            assert!(account::exists_at(addr), error::invalid_argument(EACCOUNT_DOES_NOT_EXIST));
            bucket_table::add(&mut whitelist_mint_config.whitelisted_address, addr, mint_limit);
            i = i + 1;
        };
    }

    public entry fun add_tokens(
        admin: &signer,
        token_uris: vector<String>,
        property_keys: vector<vector<String>>,
        property_values: vector<vector<vector<u8>>>,
        property_types: vector<vector<String>>
    ) acquires NFTMintConfig, CollectionConfig, WhitelistMintConfig, PublicMintConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        assert!(signer::address_of(admin) == nft_mint_config.admin, error::permission_denied(ENOT_AUTHORIZED));

        // cannot add more token uris if whitelist minting has already started
        if (exists<WhitelistMintConfig>(@mint_nft)) {
            let whitelist_mint_config = borrow_global<WhitelistMintConfig>(@mint_nft);
            assert!(whitelist_mint_config.whitelist_minting_start_time > timestamp::now_seconds(), error::permission_denied(EINVALID_UPDATE_AFTER_MINTING));
        } else {
            assert!(exists<PublicMintConfig>(@mint_nft), error::permission_denied(ECONFIG_NOT_INITIALIZED));
            let public_mint_config = borrow_global<PublicMintConfig>(@mint_nft);
            assert!(public_mint_config.public_minting_start_time > timestamp::now_seconds(), error::permission_denied(EINVALID_UPDATE_AFTER_MINTING));
        };

        assert!(exists<CollectionConfig>(@mint_nft), error::permission_denied(ECONFIG_NOT_INITIALIZED));
        assert!(vector::length(&token_uris) == vector::length(&property_keys) && vector::length(&property_keys) == vector::length(&property_values) && vector::length(&property_values) == vector::length(&property_types), error::invalid_argument(EVECTOR_LENGTH_UNMATCHED));
        let collection_config = borrow_global_mut<CollectionConfig>(@mint_nft);

        assert!(vector::length(&token_uris) + big_vector::length(&collection_config.tokens) <= collection_config.collection_maximum || collection_config.collection_maximum == 0, error::invalid_argument(EEXCEEDS_COLLECTION_MAXIMUM));
        let i = 0;
        while (i < vector::length(&token_uris)) {
            let token_uri = vector::borrow(&token_uris, i);
            assert!(!bucket_table::contains(&collection_config.added_tokens, token_uri), error::invalid_argument(EDUPLICATED_TOKENS));
            big_vector::push_back(&mut collection_config.tokens, TokenAsset {
                token_uri: *token_uri,
                property_keys: *vector::borrow(&property_keys, i),
                property_values: *vector::borrow(&property_values, i),
                property_types: *vector::borrow(&property_types, i),
            });
            bucket_table::add(&mut collection_config.added_tokens, *token_uri, true);
            i = i + 1;
        };
    }

    public entry fun mint_nft(
        nft_claimer: &signer,
        amount: u64
    ) acquires NFTMintConfig, PublicMintConfig, WhitelistMintConfig, CollectionConfig {
        assert!(exists<CollectionConfig>(@mint_nft) && exists<PublicMintConfig>(@mint_nft), error::permission_denied(ECONFIG_NOT_INITIALIZED));

        let collection_config = borrow_global<CollectionConfig>(@mint_nft);
        let public_mint_config = borrow_global_mut<PublicMintConfig>(@mint_nft);

        let now = timestamp::now_seconds();
        let is_whitelist_minting_time = false;
        if (exists<WhitelistMintConfig>(@mint_nft)) {
            let whitelist_mint_config = borrow_global<WhitelistMintConfig>(@mint_nft);
            is_whitelist_minting_time = now > whitelist_mint_config.whitelist_minting_start_time && now < whitelist_mint_config.whitelist_minting_end_time;
        };
        let is_public_minting_time = now > public_mint_config.public_minting_start_time && now < public_mint_config.public_minting_end_time;
        assert!(is_whitelist_minting_time || is_public_minting_time, error::permission_denied(EMINTING_IS_NOT_ENABLED));
        let token_uri_length = big_vector::length(&collection_config.tokens);
        assert!(amount <= token_uri_length, error::invalid_argument(ENO_ENOUGH_TOKENS_LEFT));

        let price = public_mint_config.public_mint_price;
        let claimer_addr = signer::address_of(nft_claimer);
        // if this is the whitelist minting time
        if (is_whitelist_minting_time) {
            let whitelist_mint_config = borrow_global_mut<WhitelistMintConfig>(@mint_nft);
            assert!(bucket_table::contains(&whitelist_mint_config.whitelisted_address, &claimer_addr), error::permission_denied(EACCOUNT_NOT_WHITELISTED));
            let remaining_mint_allowed = bucket_table::borrow_mut(&mut whitelist_mint_config.whitelisted_address, claimer_addr);
            assert!(*remaining_mint_allowed >= amount, error::invalid_argument(EAMOUNT_EXCEEDS_MINTS_ALLOWED));
            *remaining_mint_allowed = *remaining_mint_allowed - amount;
            price = whitelist_mint_config.whitelist_mint_price;
        } else {
            if (collection_config.public_mint_limit_per_address != 0) {
                // If the claimer's address is not on the public_minting_addresses table yet, it means this is the
                // first time that this claimer mints. We will add the claimer's address and remaining amount of mints
                // to the public_minting_addresses table.
                if (!bucket_table::contains(&public_mint_config.public_minting_addresses, &claimer_addr)) {
                    bucket_table::add(&mut public_mint_config.public_minting_addresses, claimer_addr, collection_config.public_mint_limit_per_address);
                };
                let limit = bucket_table::borrow_mut(&mut public_mint_config.public_minting_addresses, claimer_addr);
                assert!(amount <= *limit, error::invalid_argument(EAMOUNT_EXCEEDS_MINTS_ALLOWED));
                *limit = *limit - amount;
            };
        };
        mint(nft_claimer, price, amount);
    }

    public fun acquire_resource_signer(
        admin: &signer
    ): signer acquires NFTMintConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        assert!(signer::address_of(admin) == nft_mint_config.admin, error::permission_denied(ENOT_AUTHORIZED));
        create_signer_with_capability(&nft_mint_config.signer_cap)
    }

    fun mint(nft_claimer: &signer, price: u64, amount: u64) acquires NFTMintConfig, CollectionConfig {
        let nft_mint_config = borrow_global_mut<NFTMintConfig>(@mint_nft);
        let collection_config = borrow_global_mut<CollectionConfig>(@mint_nft);
        // assert there's still some tokens in the vector
        assert!(big_vector::length(&collection_config.tokens) >= amount, error::resource_exhausted(ENO_ENOUGH_TOKENS_LEFT));

        coin::transfer<AptosCoin>(nft_claimer, nft_mint_config.treasury, price * amount);
        let token_name = collection_config.token_name_base;
        string::append_utf8(&mut token_name, b": ");

        let resource_signer = create_signer_with_capability(&nft_mint_config.signer_cap);

        while(amount > 0) {
            let now = timestamp::now_microseconds();
            let index = now % big_vector::length(&collection_config.tokens);
            let bucket_index = big_vector::bucket_index(&collection_config.tokens, index);
            let token = big_vector::swap_remove(&mut collection_config.tokens, &bucket_index);

            let curr_token_name = token_name;
            let num = u64_to_string(collection_config.token_counter);
            string::append(&mut curr_token_name, num);

            let token_data_id = create_tokendata(
                &resource_signer,
                collection_config.collection_name,
                curr_token_name,
                collection_config.token_description,
                collection_config.token_maximum,
                token.token_uri,
                collection_config.royalty_payee_address,
                collection_config.royalty_points_den,
                collection_config.royalty_points_num,
                collection_config.token_mutate_config,
                token.property_keys,
                token.property_values,
                token.property_types,
            );

            let token_id = token::mint_token(&resource_signer, token_data_id, 1);
            token::direct_transfer(&resource_signer, nft_claimer, token_id, 1);

            collection_config.token_counter = collection_config.token_counter + 1;

            event::emit_event<NFTMintMintingEvent>(
                &mut nft_mint_config.token_minting_events,
                NFTMintMintingEvent {
                    token_receiver_address: signer::address_of(nft_claimer),
                    token_id,
                }
            );
            amount = amount - 1;
        };
    }

    fun u64_to_string(value: u64): String {
        if (value == 0) {
            return utf8(b"0")
        };
        let buffer = vector::empty<u8>();
        while (value != 0) {
            vector::push_back(&mut buffer, ((48 + value % 10) as u8));
            value = value / 10;
        };
        vector::reverse(&mut buffer);
        utf8(buffer)
    }
}
